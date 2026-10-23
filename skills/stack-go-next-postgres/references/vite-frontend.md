# Frontend: Vite + React + TypeScript + Tailwind CSS

Alternative to `nextjs-frontend.md` for projects where `CLAUDE.md` (or the user, for this conversation) declares Vite instead of Next.js — see `SKILL.md`'s "Frontend variant" for how that choice is made and recorded. Shares the same TypeScript rules, Tailwind tokens/conventions, and `cn` helper as the Next.js reference (not repeated here); diverges on routing, data fetching, the API client, and — importantly — production topology.

## Contents
- Setup
- Structure
- Routing (react-router)
- Data fetching (TanStack Query)
- API client
- Dev proxy and production topology
- UI states

## Setup

```bash
pnpm create vite@latest frontend -- --template react-ts
cd frontend && pnpm add react-router-dom @tanstack/react-query
pnpm add tailwindcss @tailwindcss/vite clsx tailwind-merge
pnpm add -D prettier prettier-plugin-tailwindcss
```

Unlike Next, Tailwind needs its own Vite plugin (no PostCSS pipeline auto-wired in):

```ts
// vite.config.ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
});
```

The `@theme` tokens, dark mode, and all Tailwind conventions (no dynamic class concatenation, colors from tokens, mobile-first) are identical to `nextjs-frontend.md`'s Tailwind section — set up `globals.css` the same way.

## Structure

```
src/
├── main.tsx                    # createRoot, providers, router
├── App.tsx                     # optional shared layout
├── routes/
│   ├── home.tsx
│   ├── login.tsx
│   └── posts/
│       ├── index.tsx
│       └── detail.tsx
├── components/
│   ├── ui/                     # Button, Input, Card... same as Next's
│   └── posts/
├── lib/
│   ├── api.ts                  # fetch wrapper
│   ├── auth.ts                 # useUser() hook
│   └── utils.ts                 # cn() — identical to Next's
└── types/
    └── api.ts                  # identical to Next's
```

No Server/Client Component split — everything here is a client component by nature, so skip that section of the Next reference entirely.

## Routing (react-router)

`createBrowserRouter`, with a `ProtectedRoute` wrapper standing in for Next's `middleware.ts`. The key difference: Next's middleware runs on the server and can read the `HttpOnly` cookie directly before rendering anything. Nothing server-side exists here, so "is this user logged in" can only be answered by actually calling the API — there is an unavoidable brief loading state on protected routes, not a static redirect-before-render.

```tsx
// src/main.tsx
import { createRoot } from "react-dom/client";
import { createBrowserRouter, RouterProvider } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

const queryClient = new QueryClient();

const router = createBrowserRouter([
  { path: "/", element: <HomePage /> },
  { path: "/login", element: <LoginPage /> },
  {
    element: <ProtectedRoute />,
    children: [
      { path: "/posts", element: <PostsPage /> },
      { path: "/posts/:id", element: <PostPage /> },
    ],
  },
]);

createRoot(document.getElementById("root")!).render(
  <QueryClientProvider client={queryClient}>
    <RouterProvider router={router} />
  </QueryClientProvider>,
);
```

```tsx
// src/components/protected-route.tsx
import { Navigate, Outlet } from "react-router-dom";
import { useUser } from "@/lib/auth";

export function ProtectedRoute() {
  const { data: user, isLoading, isError } = useUser();
  if (isLoading) return <Spinner />;
  if (isError || !user) return <Navigate to="/login" replace />;
  return <Outlet />;
}
```

## Data fetching (TanStack Query)

Replaces Server Components' `fetch` caching and Server Actions. `useQuery` for reads, `useMutation` + `invalidateQueries` for writes — same "the frontend's validation is UX only" rule as Next applies to any `react-hook-form` + `zod` forms here too.

```tsx
// src/lib/auth.ts
import { useQuery } from "@tanstack/react-query";
import { api } from "./api";
import type { User } from "@/types/api";

export function useUser() {
  return useQuery({ queryKey: ["me"], queryFn: () => api<User>("/me"), retry: false });
}
```

```tsx
const { data: posts, isLoading } = useQuery({
  queryKey: ["posts"],
  queryFn: () => api<Paginated<Post>>("/posts"),
});

const createPost = useMutation({
  mutationFn: (input: CreatePostInput) =>
    api<Post>("/posts", { method: "POST", body: JSON.stringify(input) }),
  onSuccess: () => queryClient.invalidateQueries({ queryKey: ["posts"] }),
});
```

## API client

Simpler than Next's version: no Server Component means no manual cookie forwarding — `credentials: "include"` makes the browser send cookies itself. Same 401-refresh-and-retry contract as `auth-jwt.md` describes, with a single-flight guard so concurrent 401s don't fire multiple refreshes:

```ts
// src/lib/api.ts
import type { ApiErrorBody } from "@/types/api";

const API_BASE = "/api/v1"; // proxied by Vite in dev; same-origin via the reverse proxy in prod

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
    public readonly fields: Record<string, string> = {},
  ) {
    super(message);
  }
}

let refreshing: Promise<void> | null = null;

export async function api<T>(path: string, init: RequestInit = {}, retried = false): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    ...init,
    credentials: "include",
    headers: { "Content-Type": "application/json", ...init.headers },
  });

  if (res.status === 401 && !retried) {
    refreshing ??= fetch(`${API_BASE}/auth/refresh`, { method: "POST", credentials: "include" })
      .then((r) => { if (!r.ok) throw new Error("refresh failed"); })
      .finally(() => { refreshing = null; });
    try {
      await refreshing;
      return api<T>(path, init, true);
    } catch {
      window.location.href = "/login";
      throw new ApiError(401, "unauthorized", "session expired");
    }
  }

  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as ApiErrorBody | null;
    throw new ApiError(res.status, body?.error.code ?? "unknown", body?.error.message ?? res.statusText, body?.error.fields);
  }
  return res.status === 204 ? (undefined as T) : ((await res.json()) as T);
}
```

## Dev proxy and production topology

**Dev** works the same way as Next's rewrite, just configured in `vite.config.ts`:

```ts
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    proxy: { "/api/v1": { target: "http://localhost:8080", changeOrigin: true } },
  },
});
```

**Production is where Vite genuinely costs more than Next.** Next.js is a running Node server, so it can keep proxying `/api/v1` in production the same way it does in dev. `vite build` produces only static files — there is no server left to proxy anything. Something else must sit in front of the static build *and* the Go API under one origin, or the `HttpOnly` cookies stop being same-origin and the whole auth model breaks. Add a small reverse proxy as its own service — Caddy is the simplest (automatic HTTPS, ~10 lines):

```
# Caddyfile
app.example.com {
	handle /api/v1/* {
		reverse_proxy api:8080
	}
	handle {
		root * /srv/dist
		try_files {path} /index.html
		file_server
	}
}
```

Add this as a `caddy` service in the production `docker-compose.yml`, mounting `frontend/dist` (the `vite build` output) and pointing `api/v1/*` at the `api` service — see `infra.md`'s "Secrets in production" for the same-file pattern applied to this service's own config if it ever needs one. This extra service is the real tradeoff against Next.js; factor it in before choosing Vite for anything that needs cookie-based auth.

## UI states

No `loading.tsx`/`error.tsx` file convention here — use TanStack Query's `isLoading`/`isError` at the call site, or a route's `errorElement` in `createBrowserRouter` for route-level failures. `notFound()` has no direct equivalent; render a 404 route (`path: "*"`) and navigate to it on a `404` `ApiError`. Dates formatted the same way as Next (`Intl.DateTimeFormat`, product locale).
