---
name: audit
description: Audit, analyze, and refactor code for reuse, decomposition, dead code, and quality. Targets a file or directory. Produces a plan, then applies changes file-by-file with user approval.
argument-hint: <path to file or directory>
---

Audit the code at `$ARGUMENTS` (a file or directory) for reuse, decomposition, dead code, duplication, and quality issues. Then refactor interactively, file-by-file, with user approval.

## Phase 1 — Analysis

Read every file in scope. For each file, check for the issues listed below. Collect all findings into a plan (use the `/plan` skill with a name like `audit_<target>`).

### What to look for

**Decomposition**
- Files longer than ~300 lines without a strong reason. Flag at 300+, suggest splitting.
- Files in the 200–300 range: flag only if they contain clearly separable concerns.
- Functions longer than ~100 lines — suggest extraction.
- A single file containing multiple unrelated types/concepts — each should be its own file.

**Reuse & duplication**
- Logic that appears in two or more places (even if not identical — structurally similar patterns count). Suggest extracting to a shared file/function.
- Be aggressive in detection. When uncertain whether two pieces are "similar enough" to unify, include the finding in the plan and mark it with **[needs decision]** so the user can weigh in.

**Dead code**
- Unused functions, properties, types, imports, files. Verify by grepping for usages before flagging.
- Commented-out code blocks.

**Code quality**
- Force unwraps where a safer alternative is trivial.
- Deeply nested logic (3+ levels) that could be flattened with early returns or extraction.
- Unclear or misleading names.
- Overly complex expressions that could be broken into named steps.
- Missing or misleading access control (only when clearly wrong).

**Project style (from CLAUDE.md)**
- Xcode boilerplate headers (`//\n//  FileName.swift\n//  ProjectName\n//`) — flag for removal.
- Useless/obvious comments that restate the code.
- Missing file-purpose comment above the primary type declaration.
- Swift `extension` blocks used as a decomposition mechanism — flag and suggest extracting to separate types/files instead.

### Plan format

Use the `/plan` skill to create the plan. In the plan:
- Group findings by file.
- For each file, list every issue found with a brief description.
- Mark duplication findings that need user input with **[needs decision]**.
- The checklist should have one item per file to be changed, plus items for new files to create.

## Phase 2 — Refactoring (file-by-file)

After the plan is created, present findings for the **first file** and ask the user to approve, skip, or adjust before making changes. Then proceed to the next file.

For each file:
1. Show the user what you intend to change (briefly — not a full diff, just the list of changes).
2. Wait for approval.
3. Apply the changes.
4. Build to confirm no compiler errors (`./build.sh`).
5. Check off the item in the plan.
6. Move to the next file.

### Refactoring rules

- When extracting to a new file, name it after the primary type/function it contains (e.g., `NextWindowInOrder.swift`).
- Keep extracted files short and focused — even a 10-line file is fine.
- When removing dead code, do a final grep to confirm it is truly unused.
- When unifying duplicated logic, place the shared code in a location that makes sense architecturally (same directory as callers, or a shared utilities directory if callers span directories).
- After each file change, build before moving on.

## Important

- Do NOT make changes without user approval on each file.
- Do NOT skip the build step between files.
- If a build fails, fix the issue before moving to the next file.
- If you are unsure about a refactoring decision, ask rather than guess.
