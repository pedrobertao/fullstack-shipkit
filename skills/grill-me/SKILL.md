---
name: grill-me
description: Relentless interview about a plan, feature or project until we reach a shared understanding. Walks down each branch of the design tree, resolving dependencies between decisions one by one, and explores the codebase before asking anything the repository already answers. Works both for kicking off a new project (ends with a filled-in CLAUDE.md and an MVP plan) and for planning a feature. Use when the user asks to "start a new project", "grill me", "interview me", "question my plan", "let's refine this idea" or wants to validate a plan before implementing it.
disable-model-invocation: true
argument-hint: [plan, feature or idea]
---

# Grill Me

Interview the user relentlessly about every aspect of the plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one by one. If a question can be answered by exploring the codebase, explore the codebase instead.

The plan to discuss is: $ARGUMENTS
If it is empty, the first question is: "Which plan, feature or idea do you want me to grill you on?"

## Two modes

- **Kickoff (new project):** the repository is empty or nearly so, `CLAUDE.md` doesn't exist or is still the unfilled template, or the user said it's a new project. Follow `references/kickoff.md`. The result is a filled-in `CLAUDE.md` and the MVP plan.
- **Feature:** the project already exists and the user wants to plan something new in it. Follow `references/decision-tree.md`. The result is the consolidated plan described at the end of this file.

When in doubt, check the repository first; if it's still unclear, ask which of the two it is.

## Why this exists

Plans fail on the decisions nobody made explicitly: the forgotten edge case, the permission "we'll figure out later", the table nobody thought to index. The goal is to surface those decisions **before** writing code, while changing your mind is still cheap. Do not write implementation code during the interview.

## Interview rules

1. **One question at a time.** Never a list of questions. Wait for the answer before moving on. Several questions at once make the user answer only the easiest one.
2. **Always with a recommendation.** Every question comes with the answer you recommend and why, in one or two sentences, so the user can just say "ok" when they agree:
   > **Question:** Can comments be edited after they're published?
   > **I recommend:** yes, for 15 minutes, storing `edited_at`. It prevents edits that change the meaning of an old discussion while still allowing typo fixes.
3. **Code before questions.** Before each question, check whether the repository already answers it: `CLAUDE.md`, the `stack-go-next-postgres` skill (if present), migrations, sqlc queries, handlers, routes, TypeScript types, `docker-compose.yml`, `.env.example`. If the answer is there, say what you found and where (e.g. "I saw in `0002_create_posts.sql` that posts have `user_id` with `ON DELETE CASCADE`, so I'll assume the same for comments") and move on. Only ask if the code is ambiguous or contradictory.
4. **Stack defaults are not questions.** If the stack skill already defines something (Fiber, sqlc, JWT in cookies, validator v10, slog, error format), assume it and don't ask. Only ask if the plan seems to need an exception.
5. **Respect dependencies.** Don't ask about the API shape before knowing which entities exist; don't ask about caching before knowing the read patterns. Follow the order of the current mode's guide and skip branches that don't apply (no async work = skip the queues branch).
6. **Be relentless, not annoying.** Don't accept vague answers ("we'll see", "whatever", "the usual"): propose a concrete answer and ask for confirmation. Point out contradictions with earlier decisions immediately. If an answer opens new branches, go down them before coming back.
7. **Dig deeper where the risk is.** Spend more questions on money, permissions, personal data, concurrency, migrating existing data and anything hard to undo. Spend fewer on cosmetic details.

## Decision log

Keep track of the decisions made during the conversation. Every 5–7 questions, show a short recap ("So far we've decided: ...") so the user can correct anything you misunderstood.

## When to stop

Stop when every applicable branch is resolved, or when the user says something like "enough", "go ahead", "that's good". If they ask to stop with important branches still open, list them as risks in the final result.

## Final result

In kickoff mode, use the result described in `references/kickoff.md`. In feature mode, when done, deliver the consolidated plan in this format:

```markdown
# Plan: <name>

## Goal
<1–3 sentences: what it is and who it's for>

## Out of scope
- ...

## Decisions
| Area | Decision | Reason |
|---|---|---|
| Data | ... | ... |

## Data model
<tables, main columns, indexes, relationships>

## API
<endpoints: method, route, auth, input, output, errors>

## Async and cache
<queues, events, Redis keys; or "not applicable">

## Frontend
<pages, states, flows>

## Edge cases
- ...

## Risks and open questions
- ...

## Implementation order
1. ...
```

Then ask whether the user wants to save the plan to `docs/plans/<name>.md` and whether any decision should go into the project's `CLAUDE.md` (only decisions that apply to the whole project, such as an exception to the stack defaults).
