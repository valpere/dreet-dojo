#!/usr/bin/env bash
# usage: minions/pr-land.sh <PR>
# Land a reviewed PR: refuse if any check is failing or pending, squash-merge with --delete-branch,
# switch to main and fast-forward, then print the last commits and the `tumanomir check docs/` line.
# Review is NOT done here — run /code-review (or /fix-review) first.
set -euo pipefail

pr=${1:?usage: minions/pr-land.sh <PR>}
repo=$(git rev-parse --show-toplevel)
cd "$repo"

checks=$(gh pr checks "$pr" 2>&1 || true)
if grep -qiE '\b(fail|pending)\b' <<<"$checks"; then
  echo "pr-land: PR #$pr checks not green:" >&2
  echo "$checks" >&2
  exit 1
fi
[[ $checks == *"no checks reported"* ]] && echo "pr-land: no CI checks on PR #$pr"

gh pr merge "$pr" --squash --delete-branch >/dev/null
state=$(gh pr view "$pr" --json state -q .state)
[[ $state == MERGED ]] || { echo "pr-land: PR #$pr state is $state, not MERGED" >&2; exit 1; }

git checkout -q main
git pull -q --ff-only
git log --oneline -3
command -v tumanomir >/dev/null && tumanomir check docs/ | head -1
