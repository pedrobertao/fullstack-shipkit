# Decision tree

Walk the branches in this order, because each one depends on the previous ones. Within each branch the questions are suggestions: use the ones that apply to the plan, come up with others when the plan calls for it, and skip whatever the code or the stack skill already answers.

## 1. Goal and scope (always)
- What problem does this solve, and for whom?
- How will we know it worked? (observable behavior, metric)
- What is explicitly **out** of this version?
- Is there a deadline or constraint that forces shortcuts? Which shortcuts are acceptable?

## 2. Domain and data (depends on 1)
- Which new entities exist, and which existing ones are touched?
- Relationships and cardinality (1:N, N:N), and what happens when the "parent" is deleted (cascade, set null, block).
- Which fields are required, unique, length-limited, restricted to fixed values?
- Is there a state/lifecycle (draft → published → archived)? Which transitions are valid?
- Soft delete or real delete?
- Is there existing production data that needs migration or backfill?
- Sequential ID or UUID (does the ID appear in a public URL)?
- Classify each entity: master data, fact/time series, computed result or join (see the stack skill's `postgres.md`). Each type raises its own questions:
  - **Facts/time series:** what is the estimated volume (sources × frequency)? How long do we keep it? Can deleting the parent master data delete this history?
  - **Computed results:** what uniquely identifies a result? Does recomputing replace the previous one or keep versions?
- Which fields have a valid range (score scale, time ranges, coordinates, quantities)? Define the exact scale, not "a number".
- Is there an implicit relationship between entities (geographic proximity, computed membership)? How will it be modeled? Is PostGIS needed?

## 3. Business rules and permissions (depends on 2)
- Who can create, read, edit and delete each entity? Owner, any logged-in user, admin, public?
- Are there limits (quantity per user, frequency)?
- What must happen atomically (same transaction)?
- Race conditions: two users at once, double clicks, repeated requests. Is idempotency needed?

## 4. API contract (depends on 2 and 3)
- Which endpoints (method + route), and which require login?
- Input for each and its validation rules (validator tags).
- Output shape; what must **not** leak in the response.
- Lists: pagination, filters, sorting, maximum size.
- Which specific errors does the frontend need to tell apart (404, 409, 422 with which fields)?

## 5. Async work (depends on 3 and 4; skip if none)
- What is too slow or too external to run inside the request?
- Which events (`entity.event`), and who consumes them?
- What happens if the consumer fails? Retry, DLQ, is someone notified?
- Is losing the event acceptable? If not, outbox.

## 6. Cache and Redis (depends on 4; skip if none)
- Which reads are frequent enough to cache?
- How long is stale data acceptable?
- Where is the cache invalidated?
- Is a specific rate limit needed?

## 7. Frontend and UX (depends on 4)
- Which pages/routes, and which are private?
- States for each page: loading, empty, error, success, not allowed.
- Server or Client Component? What needs interactivity?
- Flow after each action (redirect, refresh the list, show a toast).
- Mobile behavior.

## 8. Edge cases and failures (always)
- Boundary input (empty, huge, special characters, emoji).
- Resource deleted while another user is using it.
- Token expiring in the middle of a long form.
- Postgres, Redis or RabbitMQ unavailable: what degrades and what breaks?

## 9. Observability (always, quickly)
- Which business events deserve an `Info` log?
- What needs human attention (`Error`)?
- Is there sensitive data in this flow that must not be logged?

## 10. Tests and delivery (always)
- Which scenarios must have automated tests?
- Is the migration reversible? Does it need to run in stages (add column → backfill → make NOT NULL)?
- Feature flag or straight to production?
- Implementation order, and what can be shipped separately.
