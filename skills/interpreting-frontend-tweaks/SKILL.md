---
name: interpreting-frontend-tweaks
description: Turns a vague, casual frontend tweak ("make the button smaller", "push it down a bit", "this feels too cramped", "make it pop more") into a concrete, correctly-scoped code change instead of a guess. Locates the actual element from context, reads its current values before changing them, decides whether the change belongs on one instance or a shared component, and picks a magnitude that matches the project's existing scale rather than an arbitrary number. Use this whenever the user asks for a small visual, spacing, sizing, or color adjustment without giving exact values — on any button, card, text, spacing, or layout element.
---

# Interpreting frontend tweaks

"Make the button smaller" is underspecified on three axes at once: *which* button, smaller *by how much*, and *does this affect just this one or every button like it*. Guessing wrong on any axis means the user has to notice, explain what you got wrong, and wait for a second pass. Reading the code first collapses most of that ambiguity before you touch anything.

## Process

1. **Locate the actual element from context, not from a generic search.** If the user says "the button" right after discussing the signup form, find the signup form's button — don't grep for the first `<button` in the repo. If nothing in the recent conversation or open file narrows it down and there are two or more equally plausible candidates, that's the one case worth a quick clarifying question; otherwise proceed on your best read of the context.

2. **Read its current values before changing them.** Open the file and look at the literal classes/props/styles in place. "Smaller" is relative to what's actually there, not a generic default you'd reach for on a blank component. Skipping this step is the single most common cause of overshooting or undershooting.

3. **Decide the scope: this one instance, or every instance?**
   - A one-off element on a page → change it directly, in place.
   - A shared/reusable component (anything imported and used in multiple places) → changing its base styles changes every usage. Default to scoping the change to the call site the user is actually looking at (an override prop, a `className`/`style` override, a local wrapper) unless their phrasing implies a global change ("all my buttons feel too big", "make buttons smaller everywhere"). If a component already exposes a size/variant prop for exactly this, use it instead of hand-rolling new styles.
   - Global vs. local is the other fork worth a clarifying question when it's truly unclear — getting this wrong means either an unwanted redesign or a fix that silently doesn't apply where the user expected it.

4. **Pick a magnitude from the project's existing scale — check `globals.css` first, not a generic default.** The design system, if one exists, usually isn't in the component file itself — it's declared once and reused everywhere. In a Tailwind v4 setup (this project's), that means the `@theme` block in `globals.css`: custom spacing, font-size, radius, and color tokens defined there (`--font-sans`, `--radius-card`, custom `--color-*` steps, etc.) override Tailwind's built-in scale and are what the rest of the codebase is actually built from. Check there before touching anything:
   - **Custom token for this property exists** (e.g. a project-defined spacing or type scale) → move one step along *that* scale, not Tailwind's default one.
   - **No override for this property** → fall back to Tailwind's own built-in step (`text-sm` → `text-xs`, `py-2` → `py-1.5`, `rounded-lg` → `rounded-md`).
   - **Neither exists** (no `globals.css`/theme file, or a non-Tailwind project) → make a modest, reversible change rather than a dramatic one — it's cheaper for the user to ask for "a bit more" than to undo an overcorrection.

5. **Name what you changed, briefly.** One line is enough: what the value was, what it is now, and that it was one step on the existing scale. This gives the user a cheap way to redirect ("no, smaller than that") without you needing to have asked upfront.

## Vocabulary: default interpretations

| Phrase | Default read |
|---|---|
| "smaller" / "bigger" | one step down/up the nearest existing size scale (padding and font size together if they scale as a unit in this codebase, otherwise whichever the element visibly leads with) |
| "a bit more/less space" | one step on the spacing scale, not a specific pixel value pulled from nowhere |
| "move it up/down/left/right a bit" | a small nudge (roughly one spacing step), not a layout restructure |
| "too bold" / "not bold enough" | one font-weight step (e.g. semibold → medium), not a full restyle |
| "feels cramped" / "feels loose" | spacing (padding/gap) first, font size only if spacing alone doesn't read as the fix |
| "make it pop" / "stand out more" | one step up in visual weight — a stronger existing variant/color token, not a new ad hoc color |
| "it's too much" / "simplify it" | remove or de-emphasize the least essential element, not a blank-slate redesign |

None of these license changing anything the user didn't mention — a request about the button's size is not license to also touch its color or copy.

## When to actually ask instead of guessing

Only two situations justify a clarifying question here:
- **The element can't be narrowed down** from context (multiple genuinely plausible candidates, or none found at all).
- **Scope is a real fork** (one instance vs. every instance of a shared component) and phrasing gives no signal either way.

Everything else — magnitude, exact property, which scale step — is cheaper to just decide and state than to interrogate about, since the person can redirect in one message if the guess is off.

## Worked example

Request: *"make the button smaller"*, right after discussing a signup form.

```tsx
// src/components/ui/button.tsx (shared component, used across the app)
export function Button({ variant = "primary", className, ...props }: Props) {
  return (
    <button
      className={cn(
        "inline-flex items-center justify-center rounded-lg px-4 py-2 text-sm font-medium transition",
        variants[variant],
        className,
      )}
      {...props}
    />
  );
}
```

- **Locate:** the signup form's submit button — a `<Button>` call site, not the component file itself.
- **Current values:** `px-4 py-2 text-sm` — the base size baked into the shared component.
- **Scope:** this is a shared component; the user only mentioned one button, so scope the change to that call site rather than editing `button.tsx`. Because `className` is merged last (via `cn`/`tailwind-merge`), an override at the call site wins without touching the shared file.
- **Magnitude:** check `globals.css`'s `@theme` block first — no custom spacing or type-scale tokens defined there, so fall back to Tailwind's own default steps on both axes that define the button's size: `px-4 py-2 text-sm` → `px-3 py-1.5 text-xs`.
- **Result:** `<Button className="px-3 py-1.5 text-xs">Sign up</Button>` at that one call site, plus a one-line note: "sized the signup button down a step (px-4/py-2/text-sm → px-3/py-1.5/text-xs, no custom size tokens in globals.css so I used Tailwind's default scale); say the word if you want it smaller still or want this applied to buttons generally."
