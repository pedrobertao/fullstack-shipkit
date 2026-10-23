# Kickoff mode: starting a project

Use this guide instead of `decision-tree.md` when the project is just starting: empty or nearly empty repository, no filled-in `CLAUDE.md`, or the user said it's a new project. The goal is to leave the interview with a filled-in `CLAUDE.md` and an MVP plan ready to implement.

Decisions weigh more here than in a feature, because they become the foundation for everything. Be especially persistent on branches 1 to 3.

## 1. Product
- In one sentence: what is it and who is it for? (If it doesn't fit in one sentence, the scope isn't clear yet.)
- What real problem does it solve? How do people solve it today?
- Is it for personal use, for friends, or for unknown users on the internet? (This changes security, scale and UX effort.)
- What makes this project worth it for you: learning something, your own use, portfolio, making money?

## 2. Users and access
- Is there login? Who can create an account (anyone, invite only, just you)?
- Are there different roles (user, admin)? What can each one do?
- Is a user's data private, shared within a group, or public?
- Is social login needed for the MVP, or is email + password enough?

## 3. Domain core (the most important part)
- What are the 3 to 6 core entities? Name them.
- How do they relate? Sketch the relationships and cardinalities in text together with the user.
- What is the main action the user performs repeatedly? (the product's "loop")
- Is any data sensitive (money, health, documents, location)?
- Do IDs appear in public URLs? (decides sequential vs UUID for the whole project)
- For each entity: is it master data, fact/time series, computed result or join? Push on facts (volume, retention, what happens if the parent is deleted) and on computed results (what uniquely identifies them, whether recomputing replaces or versions).
- Is there geographic data? Just displaying coordinates, or relating things by proximity/polygons (PostGIS from the start)?

## 4. MVP scope
- What is the smallest set of features that is already genuinely useful?
- List what is left for later, explicitly. Push hard here: a bloated MVP is the most common reason personal projects get abandoned.
- Is there a deadline or milestone (e.g. using it in production by a given weekend)?

## 5. Which parts of the stack come in now
The `stack-go-next-postgres` skill defines the full stack, but not every project needs everything on day one. Question each piece:
- **Redis**: is there caching, rate limiting or refresh tokens? (With the skill's JWT auth, yes, Redis comes in.)
- **RabbitMQ**: is there real async work in the MVP (emails, heavy processing, integrations)? If not, recommend leaving the worker for later and recording that as an exception in `CLAUDE.md`.
- **Frontend**: full web app, admin panel only, or does the API also serve a mobile app (changes the JWT transport)?

## 6. External integrations
- Transactional email, payments, file storage, third-party APIs?
- For each: is it needed in the MVP? What happens when it's down?

## 7. Deployment and operations
- Where will it run (VPS, Fly.io, Railway, Render, Vercel for the frontend)? What monthly budget is acceptable?
- Custom domain? (affects auth cookies: shared parent domain or rewrite)
- Postgres backups: how and how often?
- Is a staging environment needed, or just local + production?

## 8. First milestone
- What is the first thing that must work end to end? (e.g. "sign up, log in and register a transaction")
- That thin slice becomes the first delivery; the rest of the MVP follows it.

## Kickoff result

Instead of the feature format, deliver two files:

**1. A filled-in `CLAUDE.md`**, following the project template: product description, domain (entities and rules), exceptions to the stack defaults (e.g. "no RabbitMQ in the MVP", "UUID IDs"), planned queues and commands.

**2. `docs/plans/mvp.md`** with:

```markdown
# MVP: <project name>

## Product
<the one-line sentence + who it's for>

## MVP scope
- ...

## After the MVP
- ...

## Initial data model
<tables, main columns, relationships, indexes>

## MVP endpoints
<method, route, auth>

## MVP pages
- ...

## Stack pieces
| Piece | In the MVP? | Reason |
|---|---|---|

## Deployment
<where, domain, backups>

## Risks and open questions
- ...

## Implementation order
1. Scaffold (structure, docker-compose, Makefile, auth)
2. First end-to-end slice: ...
3. ...
```

Ask before writing the files. Then offer to start with step 1 of the implementation order.
