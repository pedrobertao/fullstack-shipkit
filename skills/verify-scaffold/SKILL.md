---
name: verify-scaffold
description: Verifies end to end that a project built with the stack-go-next-postgres skill actually works, by running it instead of just reading the code. Builds and tests backend and frontend, checks sqlc drift, runs migrations up/down/up, smoke-tests the API (health, auth flow, validation and error formats), confirms the worker consumes events with the same request_id, scans logs for leaked secrets, and checks conformance with the stack conventions. Ends with a pass/fail report and proposed fixes. Use right after generating the initial project skeleton, or after large changes, when the user asks to "verify the scaffold", "check that everything works", "run the checks" or "is the project healthy".
disable-model-invocation: true
argument-hint: [layer number or name to run only that layer]
---

# Verify Scaffold

Prove that the project works by **running** it. A scaffold that compiles in your head is not verified; a scaffold whose smoke test passed is.

Scope: $ARGUMENTS
If empty, run all layers in order. If a layer number or name is given (e.g. `3` or `smoke`), run only that layer plus whatever it depends on (layer 3 needs layer 2's infra and migrations).

## Rules

1. **Run, don't assume.** Every check in `references/checks.md` has a command and a pass criterion. A check passes only if you ran the command and saw the criterion met. If a check can't be run (missing tool, no Docker), mark it **SKIPPED** with the reason; never mark it as passed.
2. **Don't fix during the run.** Record failures and keep going with independent checks, so the report shows everything at once. Only stop early if a failure blocks everything after it (e.g. the backend doesn't compile, so the smoke test is impossible); then mark the dependent checks as **BLOCKED**.
3. **Fixes only with confirmation.** After the report, propose a fix for each failure and apply them only after the user agrees. Then rerun the affected layers.
4. **Local only.** Use the local `docker-compose` and `.env`. Never point checks at a production database or URL. If `.env` points somewhere that doesn't look local (`localhost`, `127.0.0.1`, compose service names), stop and ask.
5. **Leave things as you found them.** Processes you start (API, worker, frontend) are stopped at the end. Containers can stay up (the user usually wants them), but say so. Test users created by the smoke test use `verify+<timestamp>@example.com`.
6. **Missing `.env`:** create it from `.env.example` and say so in the report. A missing variable in `.env.example` is itself a finding.

## Layers

Read `references/checks.md` for the exact commands and pass criteria.

1. **Toolchain.** Required tools are installed (Go, Node, pnpm, Docker, sqlc, goose; air is optional).
2. **Build and static checks.** Backend: `go build`, `go vet`, `go test -race`. sqlc drift: `sqlc generate` produces no diff. Frontend: `pnpm install`, `tsc --noEmit`, `lint`, `next build`.
3. **Infra and database.** `docker compose up -d`, healthchecks green, `migrate-up`, `migrate-down` all the way, `migrate-up` again. Then the migration checklist from the stack skill's `references/postgres.md` against the real schema.
4. **API smoke test.** Start API and worker with logs captured to files, then run `scripts/smoke_api.sh`: health, register → login → me → refresh → logout → me fails, 422 with `fields`, 401 on a protected route, error body format.
5. **Async and logs.** The register in layer 4 published `user.registered`; the worker consumed it, with the same `request_id`. Run `scripts/check_logs.sh` to scan API and worker logs for leaked secrets and malformed lines.
6. **Frontend integration.** Start the frontend, confirm the home page renders, an unauthenticated visit to a private route redirects to `/login`, and the `/api/v1` rewrite reaches the Go API.
7. **Conventions.** Directory layout, `.env.example` matches what `internal/config` reads, `.gitignore` covers `.env`, `node_modules`, build outputs, no committed secrets, README has the "how to run" commands.

## Report

Always finish with this format:

```markdown
# Scaffold verification: <project> — <date>

**Result:** ✅ all green | ⚠️ passed with skips | ❌ N failures

| # | Layer | Check | Status | Notes |
|---|---|---|---|---|
| 2 | Build | go vet | ✅ PASS | |
| 3 | Database | migrate down | ❌ FAIL | `DROP TABLE users` fails: sessions depends on it |
| 4 | Smoke | refresh | ⛔ BLOCKED | API didn't start |
| 1 | Toolchain | air | ⏭️ SKIPPED | not installed (optional) |

## Failures and proposed fixes
### <check>
- **What happened:** <command + relevant output, trimmed>
- **Cause:** <one or two sentences>
- **Fix:** <file and change>

## Notes
<anything created along the way: .env, test users, containers left running>
```

Then ask whether to apply the fixes. When everything is green and the directory is not yet a git repository, offer to run `git init` and make the first commit (`chore: initial scaffold`), after showing `git status` so the user sees exactly what goes in.
