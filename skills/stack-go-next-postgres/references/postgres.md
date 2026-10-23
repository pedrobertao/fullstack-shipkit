# PostgreSQL, migrations and sqlc

## Contents
- Schema conventions
- Table types (master data, facts/time series, computed results, join)
- Integrity: mandatory CHECKs
- ON DELETE policy
- Geographic data
- Migrations (goose)
- sqlc
- Pagination
- Checklist before delivering a migration

## Schema conventions

- Plural, `snake_case` table names (`users`, `blog_posts`).
- Primary key `id BIGINT GENERATED ALWAYS AS IDENTITY`. Use UUID only if the ID is exposed publicly and must not be guessable.
- Mutable tables have `created_at` and `updated_at` (`TIMESTAMPTZ NOT NULL DEFAULT now()`) plus the `set_updated_at` trigger. Immutable tables (readings, events, logs) have only `created_at`. See "Table types" below.
- Text is `TEXT` (not `VARCHAR(n)`); length limits go in a `CHECK` when they matter.
- Money as `BIGINT` (cents) or `NUMERIC(12,2)`, never `FLOAT`.
- Small enums as `TEXT` + `CHECK (status IN (...))`, which is easier to migrate than `CREATE TYPE`.
- Foreign keys always indexed, with a deliberately chosen `ON DELETE` (see "ON DELETE policy").
- Case-insensitive email uniqueness: unique index on `lower(email)`.

## Table types

Before writing a table, classify it. Each type has its own rules, and most schema problems come from treating every type the same way.

| Type | Examples | `updated_at` | Unique natural key | Typical `ON DELETE` |
|---|---|---|---|---|
| **Master data** (mutable) | users, municipalities, stations | yes | name/code when one exists | CASCADE for master-data children |
| **Facts / time series** (immutable, grows forever) | readings, events, payments | no | yes, for idempotent ingestion | **RESTRICT** from the parent |
| **Computed result** (derived from other data, recomputable) | risk_scores, reports, rankings | no (use `computed_at`) | **yes, mandatory** | CASCADE |
| **Join** (N:N) | neighborhood_stations, post_tags | no | composite PK | CASCADE on both sides |

### Master data
Has its own identity and changes over time. If it comes from an external system, uniqueness is `(source, external_code)`. To "remove" something that has history attached, prefer `active BOOLEAN NOT NULL DEFAULT true` over deleting it.

### Facts and time series
Record something that happened; they are never edited.
- Unique natural key (e.g. `(station_id, measured_at, variable)`) so the collector can run again with `INSERT ... ON CONFLICT DO NOTHING`.
- The parent uses `ON DELETE RESTRICT`: deleting master data must never destroy history by accident.
- Think about volume when creating the table: estimate rows per day (`sources × frequency × variables`). Above a few million rows per month, leave a comment on the table describing the plan (`RANGE` partitioning by time, BRIN index on `measured_at`, retention policy) and mention it to the user.

### Computed results
Produced by a job and may be recomputed. The classic mistake is having no uniqueness: the job runs twice and the data is duplicated.
- **Always** a unique index on the combination that identifies the result (e.g. `(neighborhood_id, hazard_type, period_start, period_end)`), and the job writes with `INSERT ... ON CONFLICT (...) DO UPDATE SET score = EXCLUDED.score, computed_at = now()`.
- If version history matters, that is an explicit decision: include `version` or `computed_at` in the unique key and tell the user.
- 1:1 data derived from a result (e.g. a text summary) can be a column on the same table; use a separate table only if it is generated at another time, by another process, or is large.

### Join
Composite PK, no `id` of its own; index the second PK column (the first is already covered). Relationship attributes (e.g. `distance_km`, `weight`) live here.

## Integrity: mandatory CHECKs

The database is the last line of defense; Go's validator does not protect against jobs, scripts and manual SQL. Whenever the data below appears, add the matching CHECK:

| Data | CHECK |
|---|---|
| Time range | `CHECK (period_end > period_start)` |
| Latitude / longitude | `CHECK (lat BETWEEN -90 AND 90)`, `CHECK (lon BETWEEN -180 AND 180)` |
| Score, percentage, probability | explicit range (`BETWEEN 0 AND 1` or `0 AND 100`). If the scale hasn't been defined, **ask** instead of inventing one |
| Quantity, price, distance | `CHECK (x >= 0)` or `> 0` |
| Free text from users | `CHECK (length(x) BETWEEN 1 AND N)` |
| Enum | `CHECK (x IN (...))` |
| Mutually dependent fields | e.g. `CHECK ((status = 'done') = (done_at IS NOT NULL))` |

Name the relevant CHECKs (`CONSTRAINT risk_scores_period_chk CHECK (...)`) so Postgres errors are readable.

## ON DELETE policy

Decide per relationship, using this rule:
- **CASCADE**: the child makes no sense without the parent and has no historical value (a municipality's neighborhoods, a post's comments, join rows, recomputable results).
- **RESTRICT**: the child is history or has value on its own (readings, payments, orders, audit logs). The parent is deactivated with `active = false`, not deleted.
- **SET NULL**: the reference is optional and the child survives without it (e.g. a task's `assigned_to`).

When in doubt between CASCADE and RESTRICT, choose RESTRICT: it is easy to relax later, and deleted data cannot be recovered.

## Geographic data

- If the system only stores and displays coordinates: `DOUBLE PRECISION` with the range CHECKs is enough.
- If entities are related by proximity ("stations near the neighborhood", "points within a radius"), **model the relationship**: either a precomputed join table with the distance (e.g. `neighborhood_stations`), or PostGIS (`geography(Point, 4326)` + GiST index, `postgis/postgis` image in the compose file). Never leave the relationship implicit to be recomputed on every query.
- If there are polygons (neighborhood boundaries, risk areas), use PostGIS from the start.
- This choice belongs to the user; if the plan doesn't make it clear, ask.

## Migrations (goose)

Name: `NNNN_short_description.sql` (e.g. `0003_create_comments.sql`). Always with `Down`.

```sql
-- +goose Up
CREATE TABLE comments (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    post_id     BIGINT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    user_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body        TEXT   NOT NULL CHECK (length(body) BETWEEN 1 AND 5000),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX comments_post_id_idx ON comments (post_id, created_at DESC);
CREATE INDEX comments_user_id_idx ON comments (user_id);

-- +goose Down
DROP TABLE comments;
```

Never edit a migration that has already been applied; create a new one.

For `updated_at`, create the `set_updated_at()` function once (in the first migration) and one `BEFORE UPDATE` trigger per table.

## sqlc

`backend/sqlc.yaml`:

```yaml
version: "2"
sql:
  - engine: "postgresql"
    queries: "db/queries"
    schema: "db/migrations"
    gen:
      go:
        package: "db"
        out: "internal/db"
        sql_package: "pgx/v5"
        emit_json_tags: false
        emit_empty_slices: true
        emit_pointers_for_null_types: true
```

Queries in `db/queries/<entity>.sql`, with columns listed explicitly:

```sql
-- name: GetUserByID :one
SELECT id, name, email, created_at, updated_at
FROM users
WHERE id = $1;

-- name: ListCommentsByPost :many
SELECT id, post_id, user_id, body, created_at
FROM comments
WHERE post_id = sqlc.arg(post_id)
  AND (sqlc.narg(cursor)::bigint IS NULL OR id < sqlc.narg(cursor))
ORDER BY id DESC
LIMIT sqlc.arg(page_limit);

-- name: CreateComment :one
INSERT INTO comments (post_id, user_id, body)
VALUES ($1, $2, $3)
RETURNING id, post_id, user_id, body, created_at;
```

Name queries `VerbEntity[Qualifier]`: `GetUserByEmail`, `ListPostsByUser`, `UpdatePostTitle`, `DeleteComment`.

## Pagination

Use cursor (keyset) pagination (`WHERE id < cursor ORDER BY id DESC`) instead of `OFFSET`, because it stays fast on large tables.

## Checklist before delivering a migration

Review every table against this list **before** showing the migration to the user, and fix whatever is missing:

1. Did I classify the table (master data, fact, computed, join) and apply that type's rules?
2. Is there a natural key? Does it have a unique index? Is every write from a job/collector idempotent (`ON CONFLICT`)?
3. Does every FK have an index and a justified `ON DELETE`? Could any CASCADE delete history?
4. Do all fields with a valid value range (time, coordinates, score, quantity) have a CHECK?
5. Are implicit relationships (proximity, computed membership) modeled?
6. Did I estimate the volume of ever-growing tables and record a plan if it is high?
7. Are immutable tables free of `updated_at`/trigger, and mutable ones equipped with them?
8. Does `Down` undo everything in reverse order?
9. Do the sqlc queries that use these tables exist and match the indexes created?

When delivering, list in a few lines the **assumed decisions** (e.g. "score from 0 to 1", "no PostGIS", "RESTRICT on readings") for the user to confirm or correct.
