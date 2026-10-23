# Go backend with Fiber

## Contents
- API main.go
- Config
- Fiber app and routes
- Handlers
- Validation with validator v10 (input DTOs, single instance, error messages, cross-field, frontend)
- Errors
- Output DTOs
- Logging with slog (setup, request logger, services/worker, conventions, never log)
- Transactions
- Tests

## API main.go

`main.go` only wires the pieces together: loads config, opens connections (Postgres, Redis, RabbitMQ), builds services and handlers, registers routes and starts the server with graceful shutdown.

Copy `assets/cmd/api/main.go` to `backend/cmd/api/main.go` verbatim, then adjust the wiring (constructors, `Deps` fields) to match whichever services the project actually has.

## Config

Read from environment variables with development defaults. Copy `assets/internal/config/config.go` to `backend/internal/config/config.go` verbatim.

```go
type Config struct {
	Port        string
	Env         string // "dev" | "prod"
	LogLevel    string // "debug" | "info" | "warn" | "error"
	DatabaseURL string
	RedisURL    string
	RabbitURL   string
	JWTSecret   string
	FrontendURL string // CORS and cookies
}
```

`JWTSecret`, `DatabaseURL` and `RabbitURL` — the actual secret-shaped values — are read through a `getSecret` helper instead of a plain env var lookup: it prefers a `<KEY>_FILE` path (a file on disk) over the plain `<KEY>` var, falling back to the plain var when no `_FILE` variant is set. `Load()` also fails fast (`log.Fatal`) if `JWTSecret` is empty while `Env == "prod"`. See `infra.md`'s "Secrets in production" for how `<KEY>_FILE` gets set by Docker Compose secrets once the API is containerized.

## Fiber app and routes

```go
func NewApp(log *slog.Logger, cfg config.Config, d Deps) *fiber.App {
	app := fiber.New(fiber.Config{
		ErrorHandler: errorHandler(log),
		BodyLimit:    1 * 1024 * 1024,
	})

	app.Use(recover.New())
	app.Use(requestid.New())
	app.Use(requestLogger(log))
	app.Use(cors.New(cors.Config{
		AllowOrigins:     cfg.FrontendURL,
		AllowCredentials: true,
	}))

	h := &Handlers{log: log, d: d}
	v1 := app.Group("/api/v1")

	v1.Get("/health", h.Health)

	authG := v1.Group("/auth", rateLimit(d.Redis, 10, time.Minute))
	authG.Post("/register", h.Register)
	authG.Post("/login", h.Login)
	authG.Post("/refresh", h.Refresh)
	authG.Post("/logout", h.Logout)

	// protected routes
	priv := v1.Group("", RequireAuth(d.Tokens))
	priv.Get("/me", h.Me)
	priv.Get("/users/:id", h.GetUser)
	priv.Post("/posts", h.CreatePost)

	return app
}
```

Fiber's built-in middlewares (`recover`, `requestid`, `cors`, `limiter`) are welcome; don't rewrite what already exists in `gofiber/fiber/v2/middleware`.

## Handlers

Handlers do only three things: decode the input, call the service, write the response. Business rules live in the service. Errors are **returned**, not written by hand: the central `ErrorHandler` converts them.

```go
func (h *Handlers) CreatePost(c *fiber.Ctx) error {
	var in CreatePostInput
	if err := bindAndValidate(c, &in); err != nil {
		return err
	}

	userID := CurrentUserID(c) // read from c.Locals by the JWT middleware
	post, err := h.d.Posts.Create(c.UserContext(), userID, in.Title, in.Body)
	if err != nil {
		return err
	}
	return c.Status(fiber.StatusCreated).JSON(toPostDTO(post))
}
```

Use `c.UserContext()` (not `context.Background()`) when calling services, to propagate cancellation.

**Watch out for buffers:** values from `c.Params()`, `c.Query()`, `c.Get()` and `c.Body()` are only valid during the handler. If they are kept (goroutine, cache, queue), copy them with `utils.CopyString` or `string([]byte(...))`, or enable `Immutable: true` in `fiber.Config`.

## Validation with validator v10

All input (body, query) is validated with `github.com/go-playground/validator/v10` using `validate:"..."` tags on the input DTOs. Rules that depend on the database (email already registered, resource belongs to the user) do **not** go in tags: they stay in the service and return `ErrConflict`/`ErrForbidden`.

### Input DTOs

```go
type RegisterInput struct {
	Name     string `json:"name"     validate:"required,min=2,max=100"`
	Email    string `json:"email"    validate:"required,email,max=255"`
	Password string `json:"password" validate:"required,min=8,max=72"` // bcrypt ignores anything past 72 bytes
}

type CreatePostInput struct {
	Title  string   `json:"title"  validate:"required,min=3,max=200"`
	Body   string   `json:"body"   validate:"required,max=20000"`
	Slug   string   `json:"slug"   validate:"omitempty,slug"`           // custom validator
	Tags   []string `json:"tags"   validate:"max=10,dive,min=2,max=30"` // dive validates each item
	Status string   `json:"status" validate:"required,oneof=draft published"`
}

type ListPostsQuery struct {
	Limit  int    `query:"limit"  validate:"omitempty,min=1,max=100"`
	Cursor string `query:"cursor" validate:"omitempty,numeric"`
}
```

Most-used tags: `required`, `omitempty`, `min`/`max` (length for strings/slices, value for numbers), `len`, `email`, `url`, `uuid4`, `oneof`, `numeric`, `gt`/`gte`/`lt`/`lte`, `eqfield=Password` (password confirmation), `dive` (slice/map items), `required_if`, `datetime=2006-01-02`.

For optional fields in PATCH, use pointers (`*string`) with `omitempty`, so you can tell "not sent" from "sent empty".

### Single instance (`internal/http/validate.go`)

`*validator.Validate` caches struct metadata and is safe for concurrent use: create **only one** at startup. Register the field name from the `json` tag so errors use the same names the frontend sends.

Copy `assets/internal/http/validate.go` to `backend/internal/http/validate.go` verbatim; it already includes `bindAndValidate`, `bindQueryAndValidate`, `validateStruct`, the `slug` custom validator, and the `messageFor` switch. Add a case to `messageFor` (in that file) whenever the project introduces a new `validate:"..."` tag — the mapping it implements is:

| Tag | Message |
|---|---|
| `required` | is required |
| `email` / `url` / `uuid4` / `numeric` | must be a valid email / URL / UUID / numeric |
| `oneof` | must be one of: \<values\> |
| `min` / `max` | must be at least/at most N (characters, for strings) |
| `len` | must be exactly N characters |
| `gt`/`gte`/`lt`/`lte` | must be greater/less than (or equal to) N |
| `eqfield` | does not match \<field\> |
| `slug` | must contain only lowercase letters, numbers and hyphens |
| *(unrecognized tag)* | is invalid |

Keep it as a plain `switch` in Go rather than pulling in `universal-translator` — shorter and easier to adjust. If the product's audience speaks another language, translate the strings in that switch.

### Cross-field validation

When a rule involves several fields and doesn't fit in tags (e.g. `ends_at` after `starts_at` with extra logic), register it with `validate.RegisterStructValidation(fn, MyInput{})` and report with `sl.ReportError(...)`, so the error comes out in the same `fields` format.

### Frontend

The frontend reads `error.fields` and shows each message under the matching field (the name already matches the form). `zod` validation on the frontend is just UX; validator in Go is what counts.

## Errors

Domain errors in the `service` package; an `APIError` type in the http package; and a single `ErrorHandler` that translates everything into the contract format.

```go
var (
	ErrNotFound     = errors.New("not found")
	ErrConflict     = errors.New("conflict")
	ErrUnauthorized = errors.New("unauthorized")
	ErrForbidden    = errors.New("forbidden")
)

type APIError struct {
	Status  int               `json:"-"`
	Code    string            `json:"code"`
	Message string            `json:"message"`
	Fields  map[string]string `json:"fields,omitempty"` // validation errors only
}

func (e *APIError) Error() string { return e.Message }

func errorHandler(log *slog.Logger) fiber.ErrorHandler {
	return func(c *fiber.Ctx, err error) error {
		var apiErr *APIError
		var fe *fiber.Error
		switch {
		case errors.As(err, &apiErr):
		case errors.Is(err, service.ErrNotFound):
			apiErr = &APIError{Status: 404, Code: "not_found", Message: "resource not found"}
		case errors.Is(err, service.ErrConflict):
			apiErr = &APIError{Status: 409, Code: "conflict", Message: "resource already exists"}
		case errors.Is(err, service.ErrUnauthorized):
			apiErr = &APIError{Status: 401, Code: "unauthorized", Message: "not authenticated"}
		case errors.Is(err, service.ErrForbidden):
			apiErr = &APIError{Status: 403, Code: "forbidden", Message: "not allowed"}
		case errors.As(err, &fe):
			apiErr = &APIError{Status: fe.Code, Code: "http_error", Message: fe.Message}
		default:
			log.Error("unhandled", "err", err, "path", c.Path())
			apiErr = &APIError{Status: 500, Code: "internal", Message: "internal error"}
		}
		return c.Status(apiErr.Status).JSON(fiber.Map{"error": apiErr})
	}
}
```

In the service, convert `pgx.ErrNoRows` to `ErrNotFound` and unique violations (code `23505` via `*pgconn.PgError`) to `ErrConflict`. Use `fmt.Errorf("create post: %w", err)` to add context.

## Output DTOs

Never expose sqlc-generated structs in the API; convert them to DTOs, so fields like `password_hash` never leak.

```go
type UserDTO struct {
	ID        int64     `json:"id"`
	Name      string    `json:"name"`
	Email     string    `json:"email"`
	CreatedAt time.Time `json:"created_at"`
}
```

## Logging with slog

All logging uses `log/slog` from the standard library. No `fmt.Println`, `log.Printf`, zap, zerolog or logrus, and not Fiber's built-in logger (`middleware/logger`): the request logger is written with slog so the API and worker produce the same format.

### Setup (`internal/logging`)

JSON in production (for Loki, Datadog, CloudWatch, etc.) and human-readable text in dev. Level from `LOG_LEVEL`.

```go
func New(env, level string) *slog.Logger {
	var lvl slog.Level
	if err := lvl.UnmarshalText([]byte(level)); err != nil {
		lvl = slog.LevelInfo
	}
	opts := &slog.HandlerOptions{Level: lvl, AddSource: env == "prod"}

	var h slog.Handler
	if env == "prod" {
		h = slog.NewJSONHandler(os.Stdout, opts)
	} else {
		h = slog.NewTextHandler(os.Stdout, opts)
	}
	return slog.New(h).With("service", "api") // in the worker: "worker"
}
```

### Request logger (Fiber middleware)

One line per request, always with the same fields. The logger carrying `request_id` is stored in `c.Locals` so handlers can reuse it.

```go
func requestLogger(base *slog.Logger) fiber.Handler {
	return func(c *fiber.Ctx) error {
		start := time.Now()
		reqID := c.Locals("requestid").(string)
		l := base.With("request_id", reqID)
		c.Locals("logger", l)

		err := c.Next() // the ErrorHandler has already written the status

		status := c.Response().StatusCode()
		attrs := []any{
			"method", c.Method(),
			"path", c.Route().Path, // route pattern (/users/:id), not the raw URL
			"status", status,
			"duration_ms", time.Since(start).Milliseconds(),
			"ip", c.IP(),
		}
		if uid, ok := c.Locals("user_id").(int64); ok {
			attrs = append(attrs, "user_id", uid)
		}

		switch {
		case status >= 500:
			l.Error("request", attrs...)
		case status >= 400:
			l.Warn("request", attrs...)
		default:
			l.Info("request", attrs...)
		}
		return err
	}
}

func Log(c *fiber.Ctx) *slog.Logger {
	if l, ok := c.Locals("logger").(*slog.Logger); ok {
		return l
	}
	return slog.Default()
}
```

The `requestid` middleware must come **before** `requestLogger`. In handlers, use `Log(c).Info(...)` so `request_id` shows up automatically.

### Services and worker

Services receive the logger by injection (a `log *slog.Logger` field) instead of calling `slog.Default()` behind the scenes. In the worker, each message gets a derived logger with `message_id`, `queue` and `routing_key`, and the originating `request_id` is propagated in a message header (`x-request-id`) so an operation can be traced from the API to the worker.

### Conventions

- Short, fixed, lowercase messages (`"user created"`, `"email sent"`); data goes in attributes, never interpolated into the message, so searching by message works.
- Attribute names in `snake_case` and consistent: `user_id`, `post_id`, `request_id`, `duration_ms`, `err`.
- Errors always as `"err", err`.
- Group related data with `slog.Group("db", "query", name, "rows", n)` when it helps.
- On hot paths use `logger.LogAttrs(ctx, slog.LevelDebug, "msg", slog.Int64("user_id", id))`, which avoids allocations.
- Levels: `Debug` for development detail; `Info` for business events (login, order created); `Warn` for unexpected but handled situations (retry, relevant 4xx); `Error` only for things that need human attention. An error is logged **once**, where it is handled (usually the `ErrorHandler` or the consumer), not in every layer that passes it along.

### Never log

Passwords, JWTs, refresh tokens, cookies, the `Authorization` header, config secrets or full request bodies. For sensitive types, implement `slog.LogValuer`:

```go
type Secret string

func (Secret) LogValue() slog.Value { return slog.StringValue("[REDACTED]") }
```

Emails and personal data: only when needed, preferably masked.

## Transactions

For several atomic queries: `pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error { q := queries.WithTx(tx); ... })`.

## Tests

- Handlers with Fiber's own `app.Test(httptest.NewRequest(...))`.
- Services against real Postgres, Redis and RabbitMQ via `testcontainers-go`, not mocks.
- Table-driven tests; `go test ./... -race` in the Makefile.
