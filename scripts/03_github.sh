#!/usr/bin/env bash
set -euo pipefail

# Create a GitHub repo for the current project and push the local main branch.
# Usage: ./scripts/03_github.sh [repo-name] [--public|--private]
#
# Defaults:
#   repo-name  -> basename of repo root
#   visibility -> --private
#
# Requires: gh (GitHub CLI) authenticated (`gh auth status`).

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found. Install from https://cli.github.com/ and run 'gh auth login'." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "Not inside a git repository." >&2
  exit 1
fi

cd "$REPO_ROOT"

NAME="${1:-$(basename "$REPO_ROOT")}"
VISIBILITY="--private"
if [ "${2:-}" = "--public" ] || [ "${1:-}" = "--public" ]; then
  VISIBILITY="--public"
fi
if [ "${1:-}" = "--public" ] || [ "${1:-}" = "--private" ]; then
  NAME="$(basename "$REPO_ROOT")"
fi

if git remote get-url origin >/dev/null 2>&1; then
  echo "Remote 'origin' already configured: $(git remote get-url origin)" >&2
  echo "Refusing to overwrite. Push manually with 'git push -u origin main'." >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree has uncommitted changes. Commit or stash before running this script." >&2
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "Current branch is '$CURRENT_BRANCH', expected 'main'." >&2
  exit 1
fi

echo "Creating GitHub repo '$NAME' ($VISIBILITY) and pushing main..."
gh repo create "$NAME" $VISIBILITY --source=. --remote=origin --push

echo "Done. Remote: $(git remote get-url origin)"
