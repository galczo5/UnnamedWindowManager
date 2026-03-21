---
name: update-code-md
description: Verify and update UnnamedWindowManager/CODE.md after changes. Use when files have been added, removed, renamed, or moved, or when the user wants to sync CODE.md with the current codebase.
---

Verify that `UnnamedWindowManager/CODE.md` accurately reflects the current file system, then fix any discrepancies.

## Step 1 — Scan the file system

Collect the actual files in each section by listing:

1. **Top-level**: all `.swift` and `.sh` files directly in `UnnamedWindowManager/` (exclude directories, `.md` files, and non-source files)
2. **Model**: all `.swift` files in `UnnamedWindowManager/Model/`
3. **Services subdirectories**: for each subdirectory under `UnnamedWindowManager/Services/` (Tiling, Scrolling, Handlers, Navigation, Observation, Window), list all `.swift` files
4. **Services root**: all `.swift` files directly in `UnnamedWindowManager/Services/` (not in subdirectories)

Also check for any **new subdirectories** under `Services/` that don't have a section in CODE.md, and any **new top-level directories** under `UnnamedWindowManager/` that aren't Model or Services.

## Step 2 — Read CODE.md and diff

Read `UnnamedWindowManager/CODE.md`. Compare each section's file table against the scan results. Identify:

- **Missing files**: files on disk not listed in CODE.md
- **Stale entries**: files listed in CODE.md that no longer exist on disk
- **Wrong descriptions**: only flag if a description is clearly inaccurate (e.g., file was renamed/repurposed) — do not rewrite descriptions that are merely brief

For missing files, read each file to write a one-line description matching the style of existing entries.

## Step 3 — Report and update

If there are no discrepancies, report that CODE.md is up to date and stop.

If there are discrepancies, list them for the user, then apply edits to CODE.md:

- Add new files to the correct table, maintaining alphabetical order within each section (except for Handlers, where the existing grouping convention — Focus/Swap grouped by direction, then alphabetical — should be preserved)
- Remove stale entries
- Add new sections for new Services subdirectories, following the existing format (h3 header, one-line description, pipe table)
- Update the top-level tree diagram if top-level files or directories changed

## Format rules

- Tables use `| File | Description |` headers with `|------|-------------|` separator
- File names are wrapped in backticks: `` `FileName.swift` ``
- In the Handlers section, directional handlers (Focus/Swap) are grouped as `FocusDown/Left/Right/UpHandler.swift` — preserve this convention for any new directional handler groups
- The top-level tree uses `├──` and `└──` box-drawing characters with `#` inline comments
- Keep descriptions concise (one line, sentence fragment, no trailing period)
