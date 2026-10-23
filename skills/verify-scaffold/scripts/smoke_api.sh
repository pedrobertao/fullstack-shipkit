#!/usr/bin/env bash
# Smoke test for the stack-go-next-postgres API contract.
# Usage: BASE_URL=http://localhost:8080/api/v1 ./smoke_api.sh
# Override routes via env vars if the project differs from the defaults.
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080/api/v1}"
HEALTH="${HEALTH_PATH:-/health}"
REGISTER="${REGISTER_PATH:-/auth/register}"
LOGIN="${LOGIN_PATH:-/auth/login}"
REFRESH="${REFRESH_PATH:-/auth/refresh}"
LOGOUT="${LOGOUT_PATH:-/auth/logout}"
ME="${ME_PATH:-/me}"

WORK="$(mktemp -d)"
JAR="$WORK/cookies.txt"
TS="$(date +%s)"
EMAIL="verify+${TS}@example.com"
PASSWORD="Verify-${TS}-pw!"
FAILS=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 — $2"; FAILS=$((FAILS + 1)); }

# req METHOD PATH [BODY] [extra curl args...] -> sets STATUS and BODY
req() {
  local method="$1" path="$2" body="${3:-}"; shift 3 2>/dev/null || shift $#
  local args=(-s --max-time 10 -o "$WORK/body" -w '%{http_code}' -X "$method" "$BASE_URL$path"
              -H 'Content-Type: application/json' -c "$JAR" -b "$JAR")
  [[ -n "$body" ]] && args+=(--data "$body")
  STATUS="$(curl "${args[@]}" "$@")"
  BODY="$(cat "$WORK/body")"
}

cookie() { awk -v n="$1" '$6 == n { print $7 }' "$JAR" 2>/dev/null | tail -1; }
has() { grep -q -- "$1" <<<"$BODY"; }

expect_status() { # name expected...
  local name="$1"; shift
  for s in "$@"; do [[ "$STATUS" == "$s" ]] && { pass "$name ($STATUS)"; return 0; }; done
  fail "$name" "expected $*, got $STATUS: ${BODY:0:200}"; return 1
}

expect_error_body() { # name code
  if has '"error"' && has '"code"' && has '"message"'; then
    [[ -z "${2:-}" ]] || has "\"$2\"" || { fail "$1 body" "error.code is not \"$2\": ${BODY:0:200}"; return; }
    pass "$1 body has {error:{code,message}}"
  else
    fail "$1 body" "not in {error:{code,message}} format: ${BODY:0:200}"
  fi
}

# 1. health
req GET "$HEALTH"; expect_status "health" 200

# 2. register
req POST "$REGISTER" "{\"name\":\"Verify User\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
expect_status "register" 200 201
[[ -n "$(cookie access_token)" ]] && pass "register sets access_token cookie" || fail "register cookies" "access_token cookie missing"
[[ -n "$(cookie refresh_token)" ]] && pass "register sets refresh_token cookie" || fail "register cookies" "refresh_token cookie missing"

# 3. duplicate register
req POST "$REGISTER" "{\"name\":\"Verify User\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
expect_status "duplicate register" 409 && expect_error_body "duplicate register" conflict

# 4. validation
req POST "$REGISTER" '{"name":"","email":"not-an-email","password":"x"}'
if expect_status "invalid register" 422; then
  expect_error_body "invalid register" validation
  has '"fields"' && has '"email"' && has '"password"' \
    && pass "422 lists fields.email and fields.password" \
    || fail "422 fields" "expected fields.email and fields.password: ${BODY:0:200}"
fi

# 5. malformed JSON
req POST "$REGISTER" '{"name":'
expect_status "malformed json" 400 && expect_error_body "malformed json"

# 6. wrong password
rm -f "$JAR"
req POST "$LOGIN" "{\"email\":\"$EMAIL\",\"password\":\"wrong-password\"}"
expect_status "login wrong password" 401 && expect_error_body "login wrong password" unauthorized

# 7. login
req POST "$LOGIN" "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
expect_status "login" 200

# 8. me
req GET "$ME"
if expect_status "me" 200; then
  has "$EMAIL" && pass "me returns the user" || fail "me" "email not in body"
  if has 'password'; then fail "me leaks" "body contains a password field"; else pass "me does not leak password fields"; fi
fi

# 9. refresh rotation
OLD_REFRESH="$(cookie refresh_token)"
req POST "$REFRESH"
expect_status "refresh" 200 204
NEW_REFRESH="$(cookie refresh_token)"
[[ -n "$NEW_REFRESH" && "$NEW_REFRESH" != "$OLD_REFRESH" ]] \
  && pass "refresh rotates the refresh token" \
  || fail "refresh rotation" "refresh cookie did not change"

# 10. reuse old refresh token
if [[ -n "$OLD_REFRESH" ]]; then
  STATUS="$(curl -s --max-time 10 -o "$WORK/body" -w '%{http_code}' -X POST "$BASE_URL$REFRESH" \
            -H "Cookie: refresh_token=$OLD_REFRESH")"
  BODY="$(cat "$WORK/body")"
  expect_status "reused refresh token rejected" 401
fi

# 11. logout
req POST "$LOGOUT"
expect_status "logout" 200 204

# 12. me after logout (keep the old access token to prove server-side revocation)
LAST_ACCESS="$(awk '$6 == "access_token" { print $7 }' "$JAR" | tail -1)"
req GET "$ME"
expect_status "me after logout" 401

# 13. protected route without credentials
STATUS="$(curl -s --max-time 10 -o "$WORK/body" -w '%{http_code}' "$BASE_URL$ME")"; BODY="$(cat "$WORK/body")"
expect_status "protected route without token" 401 && expect_error_body "protected route without token" unauthorized

echo
echo "test user: $EMAIL"
echo "test password: $PASSWORD"
[[ -n "${LAST_ACCESS:-}" ]] && echo "note: access token was still in the cookie jar after logout; 'me after logout' checked server-side revocation" || true
rm -rf "$WORK"
if (( FAILS > 0 )); then echo "$FAILS check(s) failed"; exit 1; fi
echo "all smoke checks passed"
