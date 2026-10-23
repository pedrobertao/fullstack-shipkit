# Infra: Docker, Makefile, env

## Contents
- docker-compose.yml (development), optional pgAdmin
- .env.example
- Makefile
- Backend Dockerfile (production)
- Secrets in production
- Frontend → Go API rewrite/proxy (mandatory)
- Starting a project from scratch

## docker-compose.yml (development)

In dev, infrastructure services run in containers; the API, worker and frontend run locally for hot reload.

Copy `assets/docker-compose.yml` to the project root verbatim. It defines `db` (Postgres), `redis` and `rabbitmq`, each with a healthcheck, plus their named volumes. If the project uses PostGIS, swap the `db` image for `postgis/postgis:17-3.5-alpine` after copying.

### Optional: pgAdmin

A local admin UI for Postgres is a convenience, not part of the always-on
stack, so it goes under a Compose profile and stays off unless asked for:

```yaml
  pgadmin:
    image: dpage/pgadmin4:latest
    profiles: ["tools"]
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@local.dev
      PGADMIN_DEFAULT_PASSWORD: admin
      PGADMIN_CONFIG_SERVER_MODE: "False"
    ports: ["5050:80"]
    volumes: [pgadmin-data:/var/lib/pgadmin]
    depends_on: [db]
```

Add `pgadmin-data:` to `volumes:`, and a Makefile target:

```makefile
pgadmin:
	docker compose --profile tools up -d pgadmin
```

`docker compose up -d` / `make infra` never starts it; `make pgadmin` does.
Connect inside pgAdmin with the same credentials as the `db` service
(host `db`, not `localhost`, since pgAdmin reaches it over the Compose
network) — or connect an external client at `localhost:<mapped port>` with
the host-side credentials from `.env`.

## .env.example

`PORT` (not `API_PORT`) here would collide with Next.js, which also
reads a `PORT` env var for `next dev` — and since the Makefile below
does `include .env; export`, every var in `.env` leaks into the `web`
target's environment too. Name the backend's port variable something
the frontend won't also claim (Vite doesn't read `PORT` by default, but
`API_PORT` is kept as the one convention either variant is safe with).

Copy `assets/.env.example` to the project root verbatim (it already uses `API_PORT`, not `PORT`, for this reason). Never commit `.env`; always commit an up-to-date `.env.example`.

## Makefile

Copy `assets/Makefile` to the project root verbatim. Targets: `infra`, `dev` (infra + api + worker + web in parallel), `api`, `worker`, `web`, `migrate-up`/`migrate-down`/`migrate-new`, `sqlc`, `test`. All read `air` if present and fall back to `go run` otherwise.

## Backend Dockerfile (production)

One Dockerfile, two binaries; the container's command picks which one runs.

Copy `assets/Dockerfile` to `backend/Dockerfile` verbatim. It builds both `cmd/api` and `cmd/worker` into a distroless image; the worker deployment overrides `ENTRYPOINT` to `/app/worker`.

In production: `ENV=prod` (JSON logs), `LOG_LEVEL=info`, cookies with `Secure`. For `JWT_SECRET` and the rest of the secret-shaped values, see the next section.

## Secrets in production

The dev `docker-compose.yml` above only containerizes `db`, `redis` and `rabbitmq` — the API and worker run on the host via `make dev`, so `.env` is fine there: it's local-only and already gitignored. Once the API/worker are containerized for deployment, switch the three actual secrets (`JWT_SECRET`, `DATABASE_URL`, `RABBITMQ_URL` — not `REDIS_URL`, which carries no credentials here) from plain env vars to Docker Compose secrets. `internal/config`'s `getSecret` (see `go-backend.md`) already prefers a `<KEY>_FILE` path over the plain var, so no code changes are needed to switch between the two:

```yaml
services:
  api:
    build: { context: ./backend, target: api }
    secrets: [jwt_secret, database_url, rabbitmq_url]
    environment:
      JWT_SECRET_FILE: /run/secrets/jwt_secret
      DATABASE_URL_FILE: /run/secrets/database_url
      RABBITMQ_URL_FILE: /run/secrets/rabbitmq_url
      ENV: prod
      LOG_LEVEL: info

  worker:
    build: { context: ./backend, target: worker }
    secrets: [database_url, rabbitmq_url]
    environment:
      DATABASE_URL_FILE: /run/secrets/database_url
      RABBITMQ_URL_FILE: /run/secrets/rabbitmq_url
      ENV: prod

secrets:
  jwt_secret:
    file: ./secrets/jwt_secret.txt
  database_url:
    file: ./secrets/database_url.txt
  rabbitmq_url:
    file: ./secrets/rabbitmq_url.txt
```

`secrets/*.txt` are gitignored, one value per file, `chmod 600`. Compose mounts each as a file at `/run/secrets/<name>`, backed by memory rather than disk: never visible in `docker inspect`, never passed to the container as an actual environment variable.

Without Docker at all (a bare VPS running the binary directly) the same pattern still works — point `JWT_SECRET_FILE` at any file on disk, e.g. `./secrets/jwt_secret.txt`. Docker isn't required for `getSecret`; Compose secrets are just one convenient way to deliver the file.

## Frontend → Go API rewrite/proxy (mandatory, even without auth)

The frontend never calls the Go API cross-origin; something makes it same-origin instead, so `HttpOnly` auth cookies work. How, depends on the resolved frontend variant (see `SKILL.md`'s "Frontend variant"):

**Next.js:** a rewrite in `frontend/next.config.ts`, on every project regardless of which other steps below are skipped:

```ts
const nextConfig: NextConfig = {
  async rewrites() {
    return [
      { source: "/api/v1/:path*", destination: `${process.env.API_URL}/api/v1/:path*` },
    ];
  },
};
```

`API_URL` must be readable by `next.config.ts` itself (evaluated at build/start time, not just by pages), which means it has to be present in the process environment when `next build`/`next start`/`next dev` run — e.g. via the root `Makefile`'s `include .env` + `export`, not just declared in `.env.example`. If the frontend is ever run standalone (not through `make dev`/`make web`), it needs its own `.env`/`.env.local` with `API_URL` or the rewrite silently resolves to `undefined/api/v1/...` and Next refuses to build. Verify this concretely — curl `/api/v1/health` through the frontend's port, not just the Go port directly — since a missing rewrite still lets the Go API's own health check pass, hiding the gap. This same rewrite keeps working unchanged in production, since Next.js is a running server there too.

**Vite:** a dev-only proxy in `vite.config.ts`, *plus* a real reverse proxy in front of both the static build and the API in production — Vite has no server of its own once built, so nothing is left to proxy anything after `vite build`. Full setup (dev config, Caddy example, where it plugs into `docker-compose.yml`) is in `references/vite-frontend.md`'s "Dev proxy and production topology" — read it before considering a Vite scaffold done; skipping the production half is the single most common way a Vite version of this stack silently breaks auth only after deploying.

## Starting a project from scratch

When asked to "create a new project", deliver in this order:

0. **Resolve the frontend variant first** (per `SKILL.md`'s "Frontend variant") — check `CLAUDE.md`, then the conversation, then default to Next.js. If this is a fresh `CLAUDE.md` being filled in (via `grill-me`'s kickoff), record the choice there so it's never re-asked.
1. Directory tree (as in SKILL.md, substituting the Vite `frontend/` structure if that's the resolved variant).
2. `docker-compose.yml`, `.env.example`, `Makefile`, `.gitignore` (see step 7 — do this now, not as an afterthought).
3. Backend: `go.mod`, config, `internal/logging`, `cmd/api/main.go` with the Fiber app, `ErrorHandler`, middlewares (`recover`, `requestid`, slog request logger, `cors`), `/health` route, `sqlc.yaml`, first migration (`users` + the `set_updated_at` function), full JWT auth (register/login/refresh/logout/me).
4. Worker: `cmd/worker/main.go`, RabbitMQ topology (exchange, DLX) and a sample consumer (`user.registered` → log a "welcome email").
5. Frontend, per the resolved variant:
   - **Next.js:** the `pnpm create next-app` command with the right flags, `globals.css` with `@theme`, `lib/utils.ts` (`cn`), `components/ui/button.tsx`, `lib/api.ts`, `types/api.ts`, `middleware.ts`, login/sign-up pages, a private page calling `/me`, **and the `next.config.ts` rewrite above**.
   - **Vite:** the `pnpm create vite` command from `references/vite-frontend.md`, `globals.css` with `@theme`, `lib/utils.ts` (`cn`), `components/ui/button.tsx`, `lib/api.ts`, `lib/auth.ts`, `types/api.ts`, the router + `ProtectedRoute` setup, login page, a protected page calling `/me`, **and the `vite.config.ts` dev proxy plus the production reverse-proxy service** from that file's last section.
6. `README.md` with "how to run": `cp .env.example .env`, `make infra`, `make migrate-up`, `make dev`.
7. `.gitignore` including `.env`, `secrets/`, `.verify/`, `node_modules/`, `.next/` (Next) or `dist/` (Vite), `tmp/`.

**Steps 6 and 7, and the rewrite/proxy in step 5, are not part of the auth/queue bundle.** When a project's `CLAUDE.md` declares exceptions (no auth, no RabbitMQ, no Redis — see the stack skill's own "exceptions" pattern), that only trims steps 3–4's auth/queue content; it never excuses skipping the README, the `.gitignore` entries, or the API rewrite/proxy — and for Vite specifically, never excuses skipping the production reverse proxy. Re-check those explicitly before calling a scaffold done, independently of whatever else got cut.

When the scaffold is done, tell the user to run `/verify-scaffold` (if that skill is installed) before building features on top of it.

Required tools: Go, Node + pnpm, Docker, `sqlc`, `goose`, `air`.
