# JWT authentication

## Contents
- Model
- Redis keys
- TokenService (`internal/auth`)
- Middleware
- Endpoints
- Frontend integration (Next.js and Vite)

## Model

- **Access token**: HS256-signed JWT, valid for **15 minutes**. Claims: `sub` (user id as a string), `exp`, `iat`, `jti` and, if needed, `role`. Nothing sensitive in the payload.
- **Refresh token**: opaque random string (32 bytes, base64url), valid for **7 to 30 days**, stored in **Redis** keyed by its SHA-256 hash. It **rotates**: each use issues a new one and invalidates the previous one.
- **Transport**: both go in `HttpOnly`, `Secure` (in prod), `SameSite=Lax` cookies. The refresh token uses `Path=/api/v1/auth` so it is only sent to the auth routes.
- **Logout**: deletes the refresh token from Redis and adds the access token's `jti` to a Redis blacklist with a TTL equal to the token's remaining lifetime.

Why this way: the short access token avoids hitting the database on every request; the refresh token in Redis allows revoking sessions; and `HttpOnly` cookies protect against theft via XSS.

If the user explicitly asks for `Authorization: Bearer` (for example, for a mobile app), accept the token in both places: header first, cookie as fallback.

## Redis keys

```
refresh:<sha256(token)>   -> user_id            TTL = refresh lifetime
user_sessions:<user_id>   -> SET of hashes      (for "log out of all devices")
jwt_blacklist:<jti>       -> 1                  TTL = exp - now
```

## TokenService (`internal/auth`)

```go
type Claims struct {
	Role string `json:"role,omitempty"`
	jwt.RegisteredClaims
}

type TokenService struct {
	secret     []byte
	rdb        *redis.Client
	accessTTL  time.Duration
	refreshTTL time.Duration
}

func (s *TokenService) NewAccess(userID int64, role string) (string, error) {
	now := time.Now()
	claims := Claims{
		Role: role,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   strconv.FormatInt(userID, 10),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(s.accessTTL)),
			ID:        uuid.NewString(),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(s.secret)
}

func (s *TokenService) ParseAccess(ctx context.Context, raw string) (*Claims, error) {
	claims := &Claims{}
	_, err := jwt.ParseWithClaims(raw, claims, func(t *jwt.Token) (any, error) {
		return s.secret, nil
	}, jwt.WithValidMethods([]string{"HS256"}))
	if err != nil {
		return nil, err
	}
	if n, _ := s.rdb.Exists(ctx, "jwt_blacklist:"+claims.ID).Result(); n > 0 {
		return nil, errors.New("token revoked")
	}
	return claims, nil
}
```

Always pass `jwt.WithValidMethods` to prevent algorithm-confusion attacks. The secret must be at least 32 random bytes.

`NewRefresh(ctx, userID)` generates the random token, stores its hash in Redis and returns the raw value. `RotateRefresh(ctx, raw)` uses `GETDEL` (atomic) to consume the old one and issue a new one; if the token doesn't exist, it returns `ErrUnauthorized`.

## Middleware

```go
func RequireAuth(tokens *auth.TokenService) fiber.Handler {
	return func(c *fiber.Ctx) error {
		raw := c.Cookies("access_token")
		if raw == "" {
			if h := c.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
				raw = strings.TrimPrefix(h, "Bearer ")
			}
		}
		if raw == "" {
			return service.ErrUnauthorized
		}
		claims, err := tokens.ParseAccess(c.UserContext(), raw)
		if err != nil {
			return service.ErrUnauthorized
		}
		id, _ := strconv.ParseInt(claims.Subject, 10, 64)
		c.Locals("user_id", id)
		c.Locals("role", claims.Role)
		return c.Next()
	}
}

func CurrentUserID(c *fiber.Ctx) int64 { return c.Locals("user_id").(int64) }

func RequireRole(role string) fiber.Handler {
	return func(c *fiber.Ctx) error {
		if c.Locals("role") != role {
			return service.ErrForbidden
		}
		return c.Next()
	}
}
```

## Endpoints

| Route | Does |
|---|---|
| `POST /auth/register` | creates the user (bcrypt), logs them in |
| `POST /auth/login` | checks the password, sets both cookies, returns `UserDTO` |
| `POST /auth/refresh` | rotates the refresh token, sets new cookies |
| `POST /auth/logout` | revokes refresh token and `jti`, clears cookies |
| `GET /me` | returns the logged-in user |

On login, return the same message for "email doesn't exist" and "wrong password", and apply rate limiting per IP + email.

## Frontend integration

- In production, the frontend and API share a parent domain (e.g. `app.site.com` and `api.site.com`, cookie with `Domain=.site.com`), or the API sits behind a same-origin proxy — Next's own rewrite, or (Vite) the reverse proxy described in `vite-frontend.md`. In dev, a rewrite/proxy is simplest either way.
- **Next.js:** Server Components forward the request cookies to the API (see `nextjs-frontend.md`'s `lib/api.ts`).
- **Vite:** nothing forwards cookies manually — `credentials: "include"` on `fetch` makes the browser do it (see `vite-frontend.md`'s `lib/api.ts`).
- On a `401`, the client calls `/auth/refresh` once and retries the request; if it fails again, it redirects to `/login`. Same contract in both variants.
- Next's `middleware.ts` runs server-side and can check for the cookie's **presence** before rendering, redirecting private routes on that alone (real validation happens in the Go API). Vite has no server-side gate — `vite-frontend.md`'s `ProtectedRoute` answers the same question by actually calling `/me`, which means a brief loading state instead of a static pre-render redirect.
