# Redis and RabbitMQ

## Redis: what it is for

| Use | Key pattern | TTL |
|---|---|---|
| Read cache | `cache:<entity>:<id>` | 5–15 min |
| Refresh tokens / JWT blacklist | see `auth-jwt.md` | token lifetime |
| Rate limiting | `rl:<route>:<ip>` | limit window |
| Simple locks | `lock:<resource>` | short, with `SET NX PX` |
| Consumer idempotency | `processed:<message_id>` | 24 h |

Rules:
- Every key has a TTL. A key without expiry is a bug.
- Prefix all keys with the project name when Redis is shared (`myapp:cache:...`).
- If Redis goes down, the API keeps working (cache misses go to Postgres). Only auth and rate limiting may fail closed.

### Cache-aside

```go
func (s *PostService) Get(ctx context.Context, id int64) (db.Post, error) {
	key := fmt.Sprintf("cache:post:%d", id)
	if b, err := s.rdb.Get(ctx, key).Bytes(); err == nil {
		var p db.Post
		if json.Unmarshal(b, &p) == nil {
			return p, nil
		}
	}
	p, err := s.q.GetPostByID(ctx, id)
	if err != nil {
		return p, mapDBErr(err)
	}
	if b, err := json.Marshal(p); err == nil {
		s.rdb.Set(ctx, key, b, 10*time.Minute)
	}
	return p, nil
}
```

On update or delete, `DEL` the key **after** the Postgres commit.

### Rate limiting

Use Fiber's `limiter` middleware with Redis storage (`gofiber/storage/redis/v3`), so the limit applies across multiple API instances.

## RabbitMQ: what it is for

Work that doesn't need to finish before the HTTP response: emails, notifications, image/file processing, webhooks and external integrations, heavy recomputations.

### Standard topology

- One `topic` exchange per project: `myapp.events`.
- Routing keys in the form `<entity>.<event>`: `user.registered`, `post.published`.
- One queue per purpose-specific consumer: `email.user_registered`, `search.index_post`.
- **Dead letter**: every queue has `x-dead-letter-exchange: myapp.dlx` and a `<name>.dlq` queue for messages that failed for good.
- Queues and exchanges `durable: true`; messages with `DeliveryMode: amqp.Persistent`.

Declare the topology on startup (both API and worker may declare it; the operation is idempotent).

### Messages

One struct per event in `internal/queue/messages.go`, always with an `id` (UUID, for idempotency), `occurred_at` and minimal data (IDs, not whole objects):

```go
type UserRegistered struct {
	ID         string    `json:"id"`
	OccurredAt time.Time `json:"occurred_at"`
	UserID     int64     `json:"user_id"`
}
```

### Publisher

A `Publisher` with one connection and one channel with **publisher confirms** enabled (`ch.Confirm(false)`), reconnecting if the connection drops (`NotifyClose`). The public method is `Publish(ctx, routingKey string, msg any) error`, which serializes to JSON, sets `MessageId`, `ContentType: application/json` and waits for the confirm.

### Consumer (worker)

`cmd/worker/main.go` opens Postgres, Redis and RabbitMQ and registers handlers:

```go
w := queue.NewWorker(conn, logger)
w.Handle("email.user_registered", "user.registered", emailSvc.HandleUserRegistered)
w.Handle("search.index_post", "post.published", searchSvc.HandlePostPublished)
w.Run(ctx) // blocks until SIGTERM
```

Consumer rules:
- `autoAck: false`; `Ack` only after successful processing.
- `Qos(prefetch=10)` per channel so the worker isn't overwhelmed.
- **Idempotent**: before processing, `SET processed:<id> 1 NX EX 86400`; if it already exists, just `Ack`.
- Transient error (timeout, external 5xx): `Nack(requeue=false)` and retry via a delay queue with TTL, or republish with a counter in the `x-retries` header; after 5 attempts it goes to the DLQ.
- Permanent error (invalid JSON, missing data): `Nack(requeue=false)` straight to the DLQ, and log it.
- A panic in a handler must not bring the worker down: recover and treat it as an error.

### Consistency (outbox)

If losing an event is unacceptable, don't publish directly from the service. Write the event to an `outbox` table **in the same transaction** as the change, and a loop in the worker reads pending `outbox` rows (`FOR UPDATE SKIP LOCKED`), publishes them and marks them as sent. For simple things (a welcome email), publishing after the commit is enough; tell the user which of the two you chose.
