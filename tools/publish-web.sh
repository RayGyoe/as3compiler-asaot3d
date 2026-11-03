#!/bin/sh
# Publish site/ to the gh-pages branch.
#
#   tools/publish-web.sh                 # build (if needed) + push gh-pages
#   tools/publish-web.sh --no-build      # push what is already in site/
#   tools/publish-web.sh --dry-run       # build the commit, do not push
#
# WHY A BRANCH AND NOT A DIRECTORY. `site/` is ~210 MB of wasm, all of it
# regenerable from source (`.gitignore` keeps it out of main), and GitHub Pages
# serves a branch root as-is. Pushing one orphan commit per publish keeps main's
# history free of binaries and makes a bad publish reversible with a re-push.
#
# The temporary repository lives under temp/ (already ignored): it holds the git
# objects only, and its work tree IS site/, so nothing is copied twice.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

REMOTE=${REMOTE:-origin}
BRANCH=${BRANCH:-gh-pages}
PUB=$(pwd)/temp/gh-pages
BUILD=1
PUSH=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --dry-run) PUSH=0 ;;
    *) echo "publish-web: unknown argument $arg" >&2; exit 2 ;;
  esac
done

if [ "$BUILD" = 1 ]; then
  if [ -z "$EMSDK_HOME" ]; then
    echo "publish-web: EMSDK_HOME is not set — a web build needs the Emscripten SDK." >&2
    exit 1
  fi
  node tools/build-web.cjs --jobs "${JOBS:-4}"
fi

[ -f site/index.html ] || { echo "publish-web: site/index.html is missing (run without --no-build)" >&2; exit 1; }
[ -f site/demos.json ] || { echo "publish-web: site/demos.json is missing (run without --no-build)" >&2; exit 1; }

# GitHub Pages runs Jekyll unless told otherwise; .nojekyll also stops it from
# dropping paths that begin with an underscore.
: > site/.nojekyll

rm -rf "$PUB"
mkdir -p "$PUB"
git init --quiet "$PUB"
# The work tree is site/: `git add -A` from there records exactly the published
# bytes, with no copy step and no chance of publishing a stale duplicate.
cd "$PUB"
GIT_DIR="$PUB/.git" GIT_WORK_TREE="$ROOT/site" git add -A

MSG="web: publish ${BUILD_TAG:-$(date -u +%Y-%m-%dT%H:%MZ)}"
GIT_DIR="$PUB/.git" GIT_WORK_TREE="$ROOT/site" git \
  -c user.name="$(git -C "$ROOT" config user.name || echo asaot3d)" \
  -c user.email="$(git -C "$ROOT" config user.email || echo asaot3d@localhost)" \
  commit --quiet -m "$MSG"

FILES=$(GIT_DIR="$PUB/.git" git ls-files | wc -l | tr -d ' ')
SIZE=$(du -sh "$ROOT/site" | cut -f1)
echo "publish-web: $FILES files, $SIZE staged as an orphan commit"

if [ "$PUSH" = 0 ]; then
  echo "publish-web: --dry-run, not pushing (repo: $PUB)"
  exit 0
fi

# --force is correct here: gh-pages carries one publish commit and nothing else,
# so there is no history to preserve and no merge to resolve.
GIT_DIR="$PUB/.git" GIT_WORK_TREE="$ROOT/site" git push --force "$REMOTE" "$BRANCH:$BRANCH" 2>&1 | sed 's/^/  /'
echo "publish-web: pushed $BRANCH to $REMOTE"
echo "publish-web: if this is the first publish, enable Pages once:"
echo "             Settings -> Pages -> Source: Deploy from a branch -> $BRANCH / (root)"