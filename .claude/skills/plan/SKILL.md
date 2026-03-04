---
name: plan
description: Create a new implementation plan document in docs/plans/
argument-hint: [plan-name or description]
---

Create a new plan file in `.claude/plans/` following the project's established format.

## Naming

- Find the next available number by listing `.claude/plans/` and incrementing the highest prefix
- File name: `NN_short_name.md` (snake_case, no spaces)

## Document structure

Use this exact section order:

```
# Plan: NN_short_name — One-Line Description

## Checklist

- [ ] Task one
- [ ] Task two
...

---

## Context / Problem

Why this is needed. What the current behaviour is. What the goal is.

---

## [Optional domain-specific sections]

E.g. "## macOS capability note", "## Behaviour spec", "## Off-screen detection"
Use these when there's non-obvious technical context that must be understood before reading the implementation.

---

## Files to create / modify

| File | Action |
|------|--------|
| `Path/To/File.swift` | **New file** — description |
| `Path/To/Other.swift` | Modify — what changes |

---

## Implementation Steps

### 1. Step name

Prose explanation.

Code blocks where the implementation is non-obvious:

\`\`\`swift
// Only show code that is genuinely illustrative
\`\`\`

### 2. Next step
...

---

## Key Technical Notes

- Bullet-point gotchas, edge cases, ordering constraints
- Anything that would cause a subtle bug if ignored

---

## Verification

1. Step-by-step manual test to confirm correct behaviour
2. Edge case checks
3. Regression scenarios
```

## Checklist rules

- Every concrete deliverable from Implementation Steps gets a checklist item
- Items are unchecked (`- [ ]`) — they get checked off as work is completed
- Granularity: one item per file created/modified or per meaningful sub-feature
- Keep items short (imperative verb phrase, ≤ 80 chars)

## Style rules

- Use `---` horizontal rules to separate major sections
- Tables for file lists (never prose lists for files)
- Code blocks only for non-trivial implementation snippets — not for trivial one-liners
- No sub-bullets inside checklist items
- Present tense in Key Technical Notes ("AX callbacks arrive on the main run loop")
- Verification steps are numbered imperatives: "Snap a window → it snaps"

## What to do

1. Read `.claude/plans/` to find the next number
2. Understand the feature from `$ARGUMENTS` and any surrounding context
3. Explore relevant source files to write accurate file paths and realistic code snippets
4. Write the plan to `.claude/plans/NN_short_name.md`
5. Report the file path to the user
