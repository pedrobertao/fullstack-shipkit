# Checks: commands and pass criteria

## Contents
1. Toolchain
2. Build and static checks
3. Infra and database
4. API smoke test
5. Async and logs
6. Frontend integration
7. Conventions
- Cleanup

Paths assume the monorepo root. Use a scratch directory for artifacts: `mkdir -p .verify` (and make sure `.verify/` is in `.gitignore`).

## 1. Toolchain

| Check | Command | Pass |
|---|---|---|
| Go | `go version` | Go ≥ the version in `backend/go.mod` |
| Node | `node --version` | ≥ 20 |
| pnpm | `pnpm --version` | present |
| Docker | `docker compose version` | present and daemon reachable (`docker info`) |
| sqlc | `sqlc version` | present |
| goose | `goose --version` | present |
| air | `air -v` | optional; SKIPPED if missing |

A missing required tool blocks the layers that need it; say how to install it.

## 2. Build and static checks

| Check | Command | Pass |
|---|---|---|
| go mod tidy | `cd backend && go mod tidy && git diff --exit-code go.mod go.sum` (skip the diff if not a git repo; compare with a copy instead) | no changes |
| build | `cd backend && go build ./...` | exit 0 |
| vet | `cd backend && go vet ./...` | exit 0 |
| tests | `cd backend && go test ./... -race` | exit 0 (no tests at all = PASS with a note) |
| sqlc drift | copy `internal/db` to `.verify/db-before`, run `sqlc generate`, `diff -r` | no differences |
| install | `cd frontend && pnpm install --frozen-lockfile` | exit 0 |
| types | `cd frontend && pnpm tsc --noEmit` | exit 0 |
| lint | `cd frontend && pnpm lint` | exit 0, no errors |
| build | `cd frontend && pnpm build` | exit 0 |

Also grep for things the stack forbids: `any` in `frontend/src` (`grep -rnE ':\s*any\b|<any>|as any' frontend/src`), `fmt.Println`/`log.Printf` in `backend/internal` and `backend/cmd`, `SELECT \*` in `backend/db/queries`. Each hit is a FAIL with file and line.

## 3. Infra and database

| Check | Command | Pass |
|---|---|---|
| up | `docker compose up -d` | exit 0 |
| healthy | `docker compose ps --format json` (poll up to 60 s) | every service `healthy` |
| migrate up | `make migrate-up` | exit 0 |
| migrate down | `cd backend && goose -dir db/migrations postgres "$DATABASE_URL" reset` | exit 0 and no tables left except `goose_db_version` (`\dt` via `docker compose exec db psql -U app -d app -c '\dt'`) |
| migrate up again | `make migrate-up` | exit 0 |
| schema review | inspect with `psql` (`\d+ <table>` for every table) | passes the checklist below, for every table |

For the schema review, check each table against this list (mirrors the stack skill's own migration checklist, so scaffolds are held to the same bar they were built with) and report each failing item, per table, with the proposed SQL:

1. Is the table classified (master data, fact, computed, join) and does it follow that type's rules?
2. Is there a natural key with a unique index? Is every job/collector write idempotent (`ON CONFLICT`)?
3. Does every FK have an index and a justified `ON DELETE`? Could any CASCADE delete history?
4. Do all fields with a valid value range (time, coordinates, score, quantity) have a CHECK?
5. Are implicit relationships (proximity, computed membership) modeled?
6. If the table grows without bound, is there a recorded volume estimate/plan?
7. Are immutable tables free of `updated_at`/trigger, and mutable ones equipped with them?
8. Does `Down` undo everything in reverse order?
9. Do the sqlc queries against this table exist and match its indexes?

## 4. API smoke test

Start the processes with captured logs (use `go run` if `air` is missing):

```bash
(cd backend && go run ./cmd/api    > ../.verify/api.log    2>&1 &) 
(cd backend && go run ./cmd/worker > ../.verify/worker.log 2>&1 &)
```

Wait until `GET /api/v1/health` returns 200 (poll up to 30 s; if it never does, the rest of layers 4–5 are BLOCKED and the last 30 lines of `api.log` go in the report).

Then run `scripts/smoke_api.sh` (from this skill's directory) with `BASE_URL=http://localhost:${PORT:-8080}/api/v1`. It prints one `PASS`/`FAIL` line per check and exits non-zero on any failure. Copy each line into the report.

What it covers:
- health 200
- register 201 (or 200) and sets `access_token`/`refresh_token` cookies
- register with the same email → 409 with `error.code`
- register with invalid body → 422 with `error.fields.email` and `error.fields.password`
- malformed JSON → 400
- login wrong password → 401
- login → 200
- me → 200 with the same email, no `password` / `password_hash` in the body
- refresh → 200 and a **different** refresh cookie
- old refresh token reused → 401 (rotation works)
- logout → 200/204
- me after logout → 401
- protected route without cookies → 401 with the error body format

If the project's routes differ from the stack defaults (see `CLAUDE.md`), adapt the script's variables instead of reporting false failures.

## 5. Async and logs

| Check | How | Pass |
|---|---|---|
| event consumed | grep `.verify/worker.log` for the `user.registered` routing key or the consumer's log line within 10 s after the smoke test | found |
| request_id propagated | take the `request_id` of the register request from `api.log` and find it in `worker.log` | same id in both |
| queues healthy | `docker compose exec rabbitmq rabbitmqctl list_queues name messages` | every queue exists; DLQs have 0 messages |
| log hygiene | `scripts/check_logs.sh .verify/api.log .verify/worker.log --password "<test password printed by smoke_api.sh>"` (add `--prod` when `ENV=prod`) | exit 0 |

`check_logs.sh` fails if logs contain the test password, JWT-shaped strings, `Bearer `, cookie headers or `password_hash`, and warns if (in `ENV=prod`) a line is not valid JSON.

## 6. Frontend integration

Start `cd frontend && pnpm start` (after the build in layer 2) or `pnpm dev`, logs to `.verify/web.log`. Source the root `.env` first (`set -a; source .env; set +a`) before building or starting — if `next.config.ts` reads `API_URL` (or similar) for its rewrite, an unexported var makes the build fail or silently resolve to `undefined/...`, and testing the Go API's own health check directly won't catch it.

| Check | Command | Pass |
|---|---|---|
| home renders | `curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/` | 200 |
| private route redirects | `curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://localhost:3000/<private route>` | 307/308 to `/login` |
| rewrite reaches Go | `curl -s http://localhost:3000/api/v1/health` | same body as the API's health |

## 7. Conventions

- Directory layout matches the stack skill's `SKILL.md` (missing folders are fine if `CLAUDE.md` records them as exceptions, e.g. no worker yet).
- Every env var read in `backend/internal/config` exists in `.env.example`, and vice versa (`grep -o 'Getenv("[A-Z_]*")'` versus the keys in `.env.example`).
- `.gitignore` covers `.env`, `.verify/`, `node_modules/`, `.next/`, Go build outputs, `tmp/` (air).
- No secrets committed: grep tracked files for `JWT_SECRET=` with a real-looking value, private keys, `.env` files other than `.env.example`.
- `README.md` has the "how to run" commands and they match the `Makefile` targets.
- `CLAUDE.md` exists and is filled in (not the template placeholders).

## Cleanup

Stop the API, worker and frontend processes you started (`pkill -f "go-build.*cmd/api"` or by the PIDs you recorded). Leave containers running and say so. Keep `.verify/` for the user to inspect; mention it in the report.
