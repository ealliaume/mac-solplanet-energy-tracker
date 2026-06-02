---
name: r1-commit
description: Commits changes with an [ai] prefix.
disable-model-invocation: true
---

You are tasked with committing the current workspace changes. Execute the following steps in order:

1. **Stage Changes:** Stage all changes in the workspace (e.g., `git add -A`).

2. **Commit Changes:** Commit the staged changes using a short, descriptive commit message.
   - The commit message MUST be prefixed exactly with `[ai] ` (e.g., `[ai] add features X and Y`).
   - If arguments were provided here -> "$ARGUMENTS" <- use them as the commit description.
   - If the arguments are empty, evaluate the git diff and generate an appropriate, concise description yourself.
