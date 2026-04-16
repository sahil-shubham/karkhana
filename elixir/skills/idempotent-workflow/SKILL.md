---
name: idempotent-workflow
description: Idempotent agent workflow — check before creating, update before duplicating.
---

Every action must be idempotent. You may be re-dispatched on the same issue multiple
times — after retries, after feedback, or after the orchestrator restarts. Before doing
anything, check the current state of things:

1. **Check Linear comments** — read all comments on this issue. If you already posted
   a plan or results, do not post duplicates. Update your existing comment if needed.
2. **Check git state** — run `git branch -a` and `git log --oneline -5` in /workspace.
   If a branch for this issue already exists, check it out instead of creating a new one.
   If a PR already exists, push to it instead of creating a new one.
3. **Check issue state** — if the issue is already In Review and you have nothing new
   to do, stop immediately.

Then do what the ticket asks:

- If the work involves code: branch from main (or reuse existing branch), implement,
  verify with `yarn build`, push, and open a PR (or update the existing one).
- If the work is research, analysis, or planning: do the work thoroughly and post
  findings as a comment.
- If the ticket asks you to create other tickets: create them via the Linear API.
