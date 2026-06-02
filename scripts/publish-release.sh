#!/usr/bin/env bash
#
# Cut a release by gating, tagging, and pushing a `vX.Y.Z` tag. The pushed tag
# triggers .github/workflows/release.yml, which does the actual build → zip +
# sha256 → GitHub Release → Homebrew tap bump (plan §3, §3.1). This script never
# builds or uploads artifacts itself, and never writes a version into any
# committed file — the tag is the single source of truth that flows into
# BUNDLE_VERSION → Info.plist.
#
# Usage:
#   ./scripts/publish-release.sh <version>      # explicit, e.g. 0.2.0
#   ./scripts/publish-release.sh patch|minor|major   # bump from latest tag
#
# Flags:
#   --skip-build   skip the local sanity build + tests
#   --yes          don't prompt before the (irreversible) tag push
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/SolplanetEnergyTracker"

SKIP_BUILD=0
ASSUME_YES=0
VERSION_ARG=""

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -*) echo "Unknown flag: $arg" >&2; exit 2 ;;
    *) VERSION_ARG="$arg" ;;
  esac
done

if [ -z "$VERSION_ARG" ]; then
  echo "Usage: $0 <version|patch|minor|major> [--skip-build] [--yes]" >&2
  exit 2
fi

die() { echo "✗ $*" >&2; exit 1; }

# --- Preconditions ---------------------------------------------------------

command -v git >/dev/null || die "git not found"
command -v gh  >/dev/null || die "gh (GitHub CLI) not found"

cd "$REPO_ROOT"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "main" ] || die "must be on 'main' (on '$CURRENT_BRANCH')"

git diff --quiet && git diff --cached --quiet || die "working tree is dirty; commit or stash first"

git ls-remote --exit-code origin >/dev/null 2>&1 || die "cannot reach 'origin'"

gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

# --- Resolve the latest existing tag --------------------------------------

# Newest vX.Y.Z tag by version sort, or empty if none exist yet.
LATEST_TAG="$(git tag --list 'v*.*.*' | sort -V | tail -1 || true)"

parse_semver() {
  # Echoes "MAJOR MINOR PATCH" for a vX.Y.Z (leading v optional). Fails on junk.
  local v="${1#v}"
  [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
}

# --- Compute the target version -------------------------------------------

case "$VERSION_ARG" in
  patch|minor|major)
    [ -n "$LATEST_TAG" ] || die "no existing vX.Y.Z tag to bump from; pass an explicit version"
    read -r MA MI PA < <(parse_semver "$LATEST_TAG") || die "latest tag '$LATEST_TAG' is not SemVer"
    case "$VERSION_ARG" in
      patch) PA=$((PA + 1)) ;;
      minor) MI=$((MI + 1)); PA=0 ;;
      major) MA=$((MA + 1)); MI=0; PA=0 ;;
    esac
    VERSION="$MA.$MI.$PA"
    ;;
  *)
    parse_semver "$VERSION_ARG" >/dev/null || die "'$VERSION_ARG' is not a valid SemVer (X.Y.Z)"
    VERSION="${VERSION_ARG#v}"
    ;;
esac

TAG="v$VERSION"

# --- Refuse to overwrite an existing tag ----------------------------------

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "tag $TAG already exists locally; releases are immutable — bump the version instead"
fi
if git ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
  die "tag $TAG already exists on origin; bump the version instead"
fi

# --- Monotonic check (guard against accidental downgrades) ----------------

if [ -n "$LATEST_TAG" ]; then
  read -r LMA LMI LPA < <(parse_semver "$LATEST_TAG")
  read -r NMA NMI NPA < <(parse_semver "$VERSION")
  if ! { [ "$NMA" -gt "$LMA" ] \
      || { [ "$NMA" -eq "$LMA" ] && [ "$NMI" -gt "$LMI" ]; } \
      || { [ "$NMA" -eq "$LMA" ] && [ "$NMI" -eq "$LMI" ] && [ "$NPA" -gt "$LPA" ]; }; }; then
    die "$VERSION is not strictly greater than latest tag ${LATEST_TAG#v}"
  fi
fi

# --- Local sanity build + tests -------------------------------------------

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "→ Sanity build (BUNDLE_VERSION=$VERSION) + tests …"
  BUNDLE_VERSION="$VERSION" "$SCRIPT_DIR/build-app-bundle.sh"
  ( cd "$PACKAGE_DIR" && swift test )
else
  echo "→ Skipping local build/tests (--skip-build)"
fi

# --- Confirm before the irreversible push ---------------------------------

COMMIT="$(git rev-parse --short HEAD)"
echo
echo "About to publish:"
echo "  version : $VERSION"
echo "  tag     : $TAG"
echo "  commit  : $COMMIT ($(git log -1 --pretty=%s))"
echo "  remote  : $(git remote get-url origin)"
echo
echo "Pushing the tag triggers the release build, GitHub Release, and tap bump."
echo "Releases are effectively immutable to consumers; to undo, ship a higher version."
echo

if [ "$ASSUME_YES" -eq 0 ]; then
  read -r -p "Proceed? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) die "aborted" ;;
  esac
fi

# --- Tag + push ------------------------------------------------------------

git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo
echo "✓ Pushed $TAG. Watch the release pipeline:"
echo "    gh run watch \$(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
echo "    gh release view $TAG"
