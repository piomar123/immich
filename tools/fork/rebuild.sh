#!/bin/bash
# cspell:ignore piomar rerere toplevel worktrees
# -----------------------------------------------------------------------------
# Rebuild the fork's `patched` branch: an upstream release + every branch in
# branches.txt (rebased onto it) + this fork-glue branch.
#
# Usage (from any checkout of the fork, with remotes `origin` = upstream and
# `fork` = piomar123/immich):
#   tools/fork/rebuild.sh [--base REF] [--no-test] [--image] [--push] [--tag NAME]
#
#   --base REF  what to build on: the latest upstream release tag (default),
#               another tag, or origin/main
#   --no-test   skip the server type check and unit tests
#   --image     build the server image immich-server-piomar:<tag> (linux/amd64)
#   --push      force-push the result to fork/patched (with lease)
#   --tag NAME  tag the result (annotated) and push the tag with --push
#
# Upstream releases are cut from release/vX.Y branches, not from main, while
# the branches here are based on main (that's where upstream PRs go). So each
# branch's own commits (not on origin/main nor on an earlier branch) are cherry-picked
# onto the base and then merged with --no-ff: one merge per branch in
# `git log --first-parent patched`, and no main-only commits in a release build.
#
# The build happens in the worktree .worktrees/patched (created if missing).
# Conflicts are replayed from git rerere; a conflict rerere has not seen stops
# the script - resolve it in .worktrees/patched, `git cherry-pick --continue`,
# and run the script again (rerere then remembers the resolution).
# -----------------------------------------------------------------------------
set -euo pipefail

BASE=""
RUN_TESTS=1
BUILD_IMAGE=0
PUSH=0
TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="$2"; shift 2 ;;
        --no-test) RUN_TESTS=0; shift ;;
        --image) BUILD_IMAGE=1; shift ;;
        --push) PUSH=1; shift ;;
        --tag) TAG="$2"; shift 2 ;;
        *) echo "Unknown option $1"; exit 1 ;;
    esac
done

REPO="$(git rev-parse --show-toplevel)"
COMMON="$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd)"
MAIN_CHECKOUT="$(dirname "$COMMON")"
WT="$MAIN_CHECKOUT/.worktrees/patched"
GLUE="fork-glue"
IMAGE_REPO="immich-server-piomar"

git -C "$REPO" fetch -q origin --tags
git -C "$REPO" fetch -q --prune fork

if [ -z "$BASE" ]; then
    BASE=$(git -C "$REPO" tag -l 'v[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
fi
BASE_SHA=$(git -C "$REPO" rev-parse --verify "$BASE^{commit}")
BASE_NAME=$(git -C "$REPO" describe --tags "$BASE_SHA")

# The branch list is read from the fork's published glue branch, so a rebuild never
# depends on what a local checkout happens to have
BRANCHES=$(git -C "$REPO" show "fork/$GLUE:tools/fork/branches.txt" | sed -e 's/#.*//' | awk 'NF {print $1}')
for b in $BRANCHES $GLUE; do
    git -C "$REPO" rev-parse --verify -q "fork/$b" >/dev/null || { echo "ERROR: fork/$b does not exist"; exit 1; }
done

if [ ! -d "$WT" ]; then
    git -C "$MAIN_CHECKOUT" worktree add -q --detach "$WT" "$BASE_SHA"
fi
cd "$WT"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "ERROR: $WT has uncommitted changes"
    exit 1
fi
git config rerere.enabled true
git config rerere.autoupdate true
git checkout -q -B patched "$BASE_SHA"

# A branch may be stacked on one listed above it: its own commits are those not on
# upstream main and not on any earlier branch
APPLIED=""
apply_one() {
    local b="$1" commits
    commits=$(git rev-list --reverse --no-merges "fork/$b" ^origin/main $APPLIED)
    APPLIED="$APPLIED ^fork/$b"
    echo "Applying $b ($(echo "$commits" | grep -c .) commits)"
    [ -n "$commits" ] || { echo "ERROR: fork/$b has no commits of its own"; exit 1; }
    git checkout -q -B "fork-build/$b" patched
    # On a conflict: continue if rerere resolved all of it, else stop for a manual resolution
    git cherry-pick -x $commits >/dev/null 2>&1 || true
    while [ -d "$(git rev-parse --git-path sequencer)" ] || [ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]; do
        if [ -n "$(git diff --name-only --diff-filter=U)" ] || git diff --cached | grep -q '^+<<<<<<< '; then
            echo "ERROR: cherry-picking $b left conflicts rerere doesn't know:"
            git diff --name-only --diff-filter=U
            echo "Resolve them in $WT, git cherry-pick --continue, then run this script again"
            exit 1
        fi
        GIT_EDITOR=true git cherry-pick --continue >/dev/null 2>&1 || true
    done
    git checkout -q patched
    git merge -q --no-ff --no-edit -m "Merge branch '$b' (rebased onto $BASE_NAME)" "fork-build/$b"
    git branch -q -D "fork-build/$b"
}

for b in $BRANCHES; do
    apply_one "$b"
done
echo "Merging $GLUE"
git merge -q --no-ff --no-edit --allow-unrelated-histories -m "Merge branch '$GLUE'" "fork/$GLUE"

if [ "$RUN_TESTS" = 1 ]; then
    PNPM_VERSION=$(sed -n 's/.*"packageManager": "pnpm@\([^"]*\)".*/\1/p' package.json)
    pn() { npx -y "pnpm@$PNPM_VERSION" "$@"; }
    LOG="$WT/server/rebuild-tests.log"
    echo "Installing dependencies and running server checks, log in $LOG"
    {
        pn install --frozen-lockfile &&
        pn --filter "@immich/plugin-sdk..." build &&
        (cd server && pn exec tsc --noEmit) &&
        (cd server && pn exec vitest run --config test/vitest.config.mjs)
    } >"$LOG" 2>&1 || { echo "ERROR: server checks failed, see $LOG"; exit 1; }
    echo "Tests passed: $(grep -E '^ +Tests ' "$LOG" | tail -1 | sed 's/^ *//')"
fi

if [ -n "$TAG" ]; then
    git tag -a "$TAG" -m "Patched build on $BASE_NAME

Branches: $(echo $BRANCHES | tr ' ' ',')"
fi

if [ "$BUILD_IMAGE" = 1 ]; then
    IMAGE="$IMAGE_REPO:${TAG:-$(git describe --tags)}"
    echo "Building $IMAGE (linux/amd64)"
    docker buildx build --platform linux/amd64 -f server/Dockerfile \
        --build-arg BUILD_SOURCE_REF="${TAG:-patched}" --build-arg BUILD_SOURCE_COMMIT="$(git rev-parse HEAD)" \
        -t "$IMAGE" --load .
fi

if [ "$PUSH" = 1 ]; then
    git push -q --force-with-lease fork patched
    [ -z "$TAG" ] || git push -q fork "refs/tags/$TAG"
fi
echo "Built patched at $(git rev-parse --short HEAD) on $BASE_NAME"
git log --oneline --first-parent "$BASE_SHA"..HEAD
