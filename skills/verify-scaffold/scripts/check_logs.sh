#!/usr/bin/env bash
# Scans log files for leaked secrets and (in prod mode) non-JSON lines.
# Usage: ./check_logs.sh <log files...> [--password <test password>] [--prod]
set -uo pipefail

FILES=(); PASSWORD=""; PROD=0
while (( $# )); do
  case "$1" in
    --password) PASSWORD="$2"; shift 2 ;;
    --prod) PROD=1; shift ;;
    *) FILES+=("$1"); shift ;;
  esac
done
(( ${#FILES[@]} )) || { echo "usage: $0 <log files...> [--password pw] [--prod]"; exit 2; }

FAILS=0
check() { # name regex
  local hits
  hits="$(grep -nE -- "$2" "${FILES[@]}" 2>/dev/null | head -5)"
  if [[ -n "$hits" ]]; then
    echo "FAIL  $1"; echo "$hits" | sed 's/^/      /'; FAILS=$((FAILS + 1))
  else
    echo "PASS  $1"
  fi
}

check "no JWT-shaped strings"        'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
check "no Bearer tokens"             'Bearer [A-Za-z0-9._-]{10,}'
check "no cookie headers"            '(Set-)?Cookie: *[a-z_]+='
check "no password hashes"           'password_hash|\$2[aby]\$[0-9]{2}\$'
check "no raw password fields"       '"password" *: *"[^"]+"|password=[^ &]+'
[[ -n "$PASSWORD" ]] && check "test password not logged" "$(printf '%s' "$PASSWORD" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"

if (( PROD )); then
  bad=0
  for f in "${FILES[@]}"; do
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      python3 -c 'import json,sys; json.loads(sys.argv[1])' "$line" 2>/dev/null || { bad=$((bad + 1)); }
    done < "$f"
  done
  (( bad == 0 )) && echo "PASS  all lines are JSON" || { echo "FAIL  $bad non-JSON line(s) in prod mode"; FAILS=$((FAILS + 1)); }
fi

(( FAILS == 0 )) && echo "log hygiene: ok" || { echo "log hygiene: $FAILS problem(s)"; exit 1; }
