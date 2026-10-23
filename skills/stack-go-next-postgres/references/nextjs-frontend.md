# Frontend: Next.js + TypeScript + Tailwind CSS

## Contents
- Setup
- TypeScript
- Structure
- Server vs Client Components
- Tailwind CSS (v4), `cn` helper and variants
- API client
- Types
- Mutations and forms
- UI states

## Setup

```bash
pnpm create next-app@latest frontend --ts --tailwind --eslint --app --src-dir --import-alias "@/*"
cd frontend && pnpm add clsx tailwind-merge
pnpm add -D prettier prettier-plugin-tailwindcss
```

- App Router, `src/` directory, `@/*` alias, `pnpm` as package manager.
- `API_URL` variable (read on the server). In dev, a rewrite in `next.config.ts` sends `/api/v1/*` to the Go API, keeping the auth cookies same-origin.

## TypeScript

`tsconfig.json` with, beyond the Next defaults:

```json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "forceConsistentCasingInFileNames": true
  }
}
```

Rules:
- No `any`. For data of unknown shape use `unknown` and validate it (with `zod` when it comes from outside, e.g. forms).
- `type` for data shapes and props; `interface` only when you need extension/declaration merging.
- Explicitly typed props; components as `function Name(props: Props)`, not `React.FC`.
- No `as` to silence the compiler; needing it is a sign the type is wrong.
- Discriminated unions for states (`{ status: "loading" } | { status: "ok"; data: T } | { status: "error"; error: string }`).
- `pnpm tsc --noEmit` runs in `make test`.

## Structure

```
src/
├── app/
│   ├── layout.tsx
│   ├── globals.css             # Tailwind + theme
│   ├── page.tsx
│   ├── (auth)/login/page.tsx
│   ├── (app)/                  # private routes
│   │   ├── layout.tsx
│   │   └── posts/
│   │       ├── page.tsx
│   │       ├── [id]/page.tsx
│   │       └── actions.ts      # Server Actions
├── components/
│   ├── ui/                     # Button, Input, Card, Badge...
│   └── posts/                  # feature components
├── lib/
│   ├── api.ts                  # single Go API client
│   └── utils.ts                # cn()
├── middleware.ts               # redirects private routes without a cookie
└── types/
    └── api.ts                  # types mirroring the Go DTOs
```

## Server vs Client Components

- **Server Component is the default.** Fetch data on the server and pass it down as props.
- `"use client"` only where there is state, events or browser hooks, and at the leaves of the tree.

## Tailwind CSS (v4)

Configuration lives **in CSS**, not in `tailwind.config.js`. Project tokens go in `@theme` in `globals.css`:

```css
@import "tailwindcss";

@theme {
  --color-brand-50: oklch(0.97 0.02 250);
  --color-brand-500: oklch(0.6 0.18 250);
  --color-brand-600: oklch(0.52 0.19 250);
  --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif;
  --radius-card: 0.75rem;
}

@custom-variant dark (&:where(.dark, .dark *));
```

This generates classes like `bg-brand-500` and `rounded-card`. Dark mode via the `dark` class on `<html>`.

Rules:
- Utility classes directly in JSX. No CSS Modules, styled-components or scattered `@apply`; `@apply` only in rare cases (e.g. styling HTML rendered from markdown).
- Colors always from the `@theme` tokens, not arbitrary values (`bg-[#3b82f6]`), to keep things consistent.
- Mobile first: base class for mobile, `sm:`/`md:`/`lg:` for larger screens.
- Class order is handled by `prettier-plugin-tailwindcss`.
- Never build classes by dynamic concatenation (`` `bg-${color}-500` ``); Tailwind can't detect them. Use a map of complete strings.
- Accessible states: always `focus-visible:` on interactive elements and `disabled:` on buttons.
- Same set of classes repeated 3 times: extract a component into `components/ui`.

### `cn` helper and variants

```ts
// src/lib/utils.ts
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
```

```tsx
// src/components/ui/button.tsx
import { cn } from "@/lib/utils";
import type { ButtonHTMLAttributes } from "react";

const variants = {
  primary: "bg-brand-600 text-white hover:bg-brand-500",
  secondary: "bg-zinc-100 text-zinc-900 hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-100",
  ghost: "hover:bg-zinc-100 dark:hover:bg-zinc-800",
} as const;

type Props = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: keyof typeof variants;
};

export function Button({ variant = "primary", className, ...props }: Props) {
  return (
    <button
      className={cn(
        "inline-flex items-center justify-center rounded-lg px-4 py-2 text-sm font-medium transition",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand-500",
        "disabled:pointer-events-none disabled:opacity-50",
        variants[variant],
        className,
      )}
      {...props}
    />
  );
}
```

No component library by default; `shadcn/ui` if the user asks (it already follows this same `cn` + Tailwind pattern).

## API client

A single place that knows the URL, forwards cookies and handles the backend's error format. In Server Components:

```ts
// src/lib/api.ts
import { cookies } from "next/headers";
import type { ApiErrorBody } from "@/types/api";

const API_URL = process.env.API_URL ?? "http://localhost:8080";

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

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const cookieHeader = (await cookies()).toString();

  const res = await fetch(`${API_URL}/api/v1${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(cookieHeader ? { Cookie: cookieHeader } : {}),
      ...init.headers,
    },
    cache: init.cache ?? "no-store",
  });

  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as ApiErrorBody | null;
    throw new ApiError(
      res.status,
      body?.error.code ?? "unknown",
      body?.error.message ?? res.statusText,
      body?.error.fields,
    );
  }
  return res.status === 204 ? (undefined as T) : ((await res.json()) as T);
}
```

In Client Components, use a version with `credentials: "include"` that, on a `401`, calls `POST /api/v1/auth/refresh` once and retries the request; if it fails again, it redirects to `/login` (see `auth-jwt.md`).

## Types

Mirror the Go DTOs with the same field names (`snake_case`). Dates arrive as `string`.

```ts
// src/types/api.ts
export type User = {
  id: number;
  name: string;
  email: string;
  created_at: string;
};

export type Paginated<T> = { items: T[]; next_cursor: string | null };
export type ApiErrorBody = {
  error: { code: string; message: string; fields?: Record<string, string> };
};
```

When a DTO changes in Go, update this file in the same response.

## Mutations and forms

Simple forms: Server Actions calling `api()` followed by `revalidatePath`. Forms with rich client-side validation: `react-hook-form` + `zod` (the form type comes from `z.infer<typeof schema>`). The validation that counts is the Go one (validator v10); the frontend's is just UX. When the API responds with `422`, iterate over `error.fields` and apply each message to the field with the same name (with react-hook-form's `setError`, or by returning the map from the Server Action and showing it under each input).

## UI states

Every route that fetches data has `loading.tsx` (skeleton with `animate-pulse`) and `error.tsx`. `notFound()` when the API returns 404. Dates formatted with `Intl.DateTimeFormat` using the product's locale (e.g. `"pt-BR"` or `"en-US"`).
