# fullstack-shipkit

A small set of [Claude Code](https://claude.com/claude-code) skills I use on my own projects: plan an idea properly, scaffold it on a fixed stack, prove it runs, and handle the endless "make it a bit smaller" requests without guesswork.

## Skills

| Skill | What it does | How it runs |
| --- | --- | --- |
| [`grill-me`](skills/grill-me/SKILL.md) | Interviews you about a plan, feature or new project, one decision at a time, until nothing is left implicit. For a new project it ends with a filled-in `CLAUDE.md` and an MVP plan. | Manual: `/grill-me <idea>` |
| [`stack-go-next-postgres`](skills/stack-go-next-postgres/SKILL.md) | Conventions for building on Go (Fiber), React + TypeScript + Tailwind (Next.js, or Vite + React Router + TanStack Query), PostgreSQL, Redis, RabbitMQ, JWT auth and `slog` logging. Includes starter files in `assets/`. | Automatic when you work on that stack |
| [`verify-scaffold`](skills/verify-scaffold/SKILL.md) | Runs the project for real: builds, tests, `sqlc` drift, migrations up/down/up, API smoke tests, worker events, log scan for leaked secrets. Ends with a pass/fail report. | Manual: `/verify-scaffold [layer]` |
| [`interpreting-frontend-tweaks`](skills/interpreting-frontend-tweaks/SKILL.md) | Turns vague UI requests ("push it down a bit", "make it pop") into a scoped change sized to the project's existing scale. | Automatic |

The first three are meant to be used in order:

```
grill-me  →  stack-go-next-postgres  →  verify-scaffold
 (plan)          (build)                 (prove it works)
```

`interpreting-frontend-tweaks` works on any frontend, whatever the stack.

## Install

### As a plugin (recommended)

In Claude Code:

```
/plugin marketplace add pedrobertao/fullstack-shipkit
/plugin install fullstack-shipkit@fullstack-shipkit
```

Plugin skills are namespaced, so the manual ones become `/fullstack-shipkit:grill-me` and `/fullstack-shipkit:verify-scaffold`.

### Manually

Copy any folder from `skills/` into `~/.claude/skills/` (every project) or `.claude/skills/` (one project):

```bash
git clone https://github.com/pedrobertao/fullstack-shipkit.git
cp -r fullstack-shipkit/skills/grill-me ~/.claude/skills/
```

## Notes

- `stack-go-next-postgres` reflects my own stack choices. Fork it and change the conventions to match yours.
- `verify-scaffold` only runs against local services (`localhost` and Docker Compose). It stops and asks if `.env` points anywhere else.
- Credentials in `assets/` (`app`/`app`, `replace-with-32-random-bytes`) are local dev placeholders.

## License

[MIT](LICENSE)
