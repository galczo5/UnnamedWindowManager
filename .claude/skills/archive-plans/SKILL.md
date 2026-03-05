---
name: archive-plans
description: Archive old implementation plans. Use when user wants to archive, squash, or consolidate old plans. Triggered by phrases like "archive plans", "squash plans", "consolidate plans NN and MM", "archive plan 03".
argument-hint: [plan-numbers to archive, e.g. "02 03" or "2,3"]
---

Archive the specified plans into a single summary entry, then renumber all remaining plans.

## What to do

### 1. Parse the plan numbers

Extract the plan numbers to archive from `$ARGUMENTS`. Accept space- or comma-separated numbers (e.g. `02 03` or `2,3` or `2, 3`).

### 2. Read and understand the plans being archived

For each plan number to archive, read `.claude/plans/NN_*.md`. Extract:
- The one-line description from the `# Plan:` heading
- The **Context / Problem** section (why it was needed, what it changed)
- Any important file paths from the **Files to create / modify** table — keep file paths but omit the action column details
- The overall goal/outcome, inferred from the plan

Do **not** include: checklists, code blocks, implementation steps, key technical notes, or verification steps.

### 3. Create the archived summary plan

The archived plan replaces the lowest-numbered plan being archived. Its number slot stays, but renumbering happens after.

Create `.claude/plans/NN_archived.md` (where NN is the position after renumbering — see step 5) with this structure:

```
# Plan: NN_archived — [ARCHIVED] Short Description of What Was Covered

> **Archived** — This entry consolidates plans [list original numbers and names].
> These plans have been completed and their details removed. Only key context is preserved.

---

## What This Covered

[1-3 sentence prose summary of what the archived plans accomplished together. No bullet points.]

---

## Plans Consolidated

| Original # | Name | Summary |
|---|---|---|
| 01 | `01_init` | One sentence of what it did |
| 02 | `02_resize` | One sentence of what it did |

---

## Important Files

[List of file paths that were created or significantly modified by these plans. One path per line, in backticks. No descriptions needed.]

---
```

Keep the archived plan concise — it is a record, not a guide.

### 4. Delete the old plan files

Delete all the original plan files that were archived (all of them, including the lowest-numbered one — the archived summary gets a fresh file).

### 5. Renumber all remaining plans

After deletion, collect all remaining plans plus the new archived summary. Sort them by their intended logical order (archived summary takes the slot of the lowest archived number; plans that came after the archived ones shift down to fill gaps).

Rename files so numbering is gapless and sequential starting from 01. Use two-digit zero-padded prefixes.

**Example:**
- Before: 01, 02, 03, 04 — archiving 02 and 03
- After: `01_init.md` (unchanged), `02_archived.md` (new), `03_horizontal.md` (was 04)

Only rename files whose number actually changes. Do not touch file contents during renaming — only the filename prefix changes.

### 6. Report back

Tell the user:
- Which plans were archived
- The name of the new archived summary file
- Which files were renumbered and what their new names are
