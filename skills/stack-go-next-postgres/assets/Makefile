include .env
export

.PHONY: infra dev api worker web migrate-up migrate-down migrate-new sqlc test

infra:
	docker compose up -d

api:
	cd backend && (command -v air >/dev/null 2>&1 && air -c .air.api.toml || go run ./cmd/api)

worker:
	cd backend && (command -v air >/dev/null 2>&1 && air -c .air.worker.toml || go run ./cmd/worker)

web:
	cd frontend && pnpm dev

dev: infra
	$(MAKE) -j3 api worker web

migrate-up:
	cd backend && goose -dir db/migrations postgres "$(DATABASE_URL)" up

migrate-down:
	cd backend && goose -dir db/migrations postgres "$(DATABASE_URL)" down

migrate-new:
	cd backend && goose -dir db/migrations create $(name) sql

sqlc:
	cd backend && sqlc generate

test:
	cd backend && go vet ./... && go test ./... -race
	cd frontend && pnpm lint && pnpm tsc --noEmit
