# Code Style

## File Size & Decomposition

Prefer small, focused files. When a file grows large, decompose it into multiple smaller files by extracting types, structs, or classes into their own files.

Do NOT use Swift `extension` blocks as a decomposition mechanism. Instead of splitting a type across multiple files via extensions, extract distinct functionality into separate types or files with their own primary declarations.

## Comments

Do not add useless or obvious comments that restate what the code clearly does. This includes Xcode-generated file header boilerplate (`//\n//  FileName.swift\n//  ProjectName\n//`) — remove it.

Place a brief comment above the primary type declaration (class, struct, enum) in each file explaining the file's purpose. Avoid inline comments unless the logic is genuinely non-obvious.
