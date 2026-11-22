#!/usr/bin/env bash
# usage: minions/pr-land.sh <PR>
# Land a reviewed PR: allow only checks in the pass/skipping buckets (or no checks at all), squash-merge
# with --delete-branch, switch to main and fast-forward, then print the last commits and the
# `tumanomir check docs/` line. Exit 1 = refused/not merged; exit 0 = merged (trailing info is best-effort).
# Review is NOT done here — run /code-review (or /fix-review) first.
set -euo pipefail

pr=${1:?usage: minions/pr-land.sh <PR>}
cd "$(git rev-parse --show-toplevel)"

rc=0
buckets=$(gh pr checks "$pr" --json name,bucket -q '.[] | "\(.bucket)\t\(.name)"' 2>&1) || rc=$?
if [[ $rc -ne 0 ]]; then
  if [[ $buckets == *"no checks reported"* ]]; then
    echo "pr-land: no CI checks on PR #$pr"
    buckets=""
  else
    echo "pr-land: cannot read checks for PR #$pr (rc=$rc): $buckets" >&2
    exit 1
  fi
fi
bad=$(awk -F'\t' '$1 != "pass" && $1 != "skipping"' <<<"$buckets" | sed '/^$/d')
if [[ -n $bad ]]; then
  echo "pr-land: PR #$pr has checks that are not pass/skipping:" >&2
  echo "$bad" >&2
  exit 1
fi

gh pr merge "$pr" --squash --delete-branch >/dev/null
state=$(gh pr view "$pr" --json state -q .state)
[[ $state == MERGED ]] || { echo "pr-land: PR #$pr state is $state, not MERGED" >&2; exit 1; }

git checkout -q main
git pull -q --ff-only
git log --oneline -3
if command -v tumanomir >/dev/null; then
  { tumanomir check docs/ || true; } | sed -n 1p
fi
exit 0
