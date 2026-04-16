---
name: git-workflow
description: Git branching, PR creation, and code push workflow for karkhana agents.
---

## Code workflow

Only when the task involves code changes:

```bash
cd /workspace

# Check for existing branch
BRANCH="{{ issue.identifier | downcase }}"
if git branch -a | grep -q "$BRANCH"; then
  git checkout "$BRANCH"
  git pull origin "$BRANCH" 2>/dev/null || true
  git merge main --no-edit
else
  git checkout main && git pull origin main
  git checkout -b "$BRANCH"
fi

# ... make changes ...
yarn build  # must pass before pushing

git add -A && git commit -m "{{ issue.identifier }}: <concise description>"
git push -u origin "$BRANCH"

# Create PR only if one doesn't exist
if ! gh pr list --head "$BRANCH" --json number --jq '.[0].number' | grep -q .; then
  gh pr create --title "{{ issue.identifier }}: {{ issue.title }}" \
    --body "Resolves {{ issue.identifier }}" --base main
fi
```
