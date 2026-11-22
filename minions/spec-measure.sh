#!/usr/bin/env bash
# usage: minions/spec-measure.sh [git-rev] [set...]
# Snapshot docs/ spec sets at <git-rev> (default HEAD) into ../context/tumanomir/specs/ (read-only),
# run `tumanomir measure` on each one sequentially with that dir's .tumanomir.yaml (corpus.enabled
# appends/dedups corpus.jsonl), keep the full report + stderr + runs.tsv, and print a summary table.
# Sets: req-uc (requirements.md + use-cases.md) and hld (hld.md). Default: both.
# Sequential on purpose: tumanomir v0.1 has no corpus file locking.
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
ctx="$repo/../context/tumanomir"
rev=$(git -C "$repo" rev-parse --short "${1:-HEAD}")
shift || true
sets=("$@")
[[ ${#sets[@]} -eq 0 ]] && sets=(req-uc hld)

files_for() {
  case "$1" in
    req-uc) echo "docs/requirements.md docs/use-cases.md" ;;
    hld) echo "docs/hld.md" ;;
    *) echo "spec-measure: unknown set '$1' (req-uc|hld)" >&2; exit 2 ;;
  esac
}

for set in "${sets[@]}"; do files_for "$set" >/dev/null; done # validate before any work
[[ -f "$ctx/.tumanomir.yaml" ]] || { echo "spec-measure: missing $ctx/.tumanomir.yaml" >&2; exit 2; }
mkdir -p "$ctx/specs" "$ctx/reports"

snapshot() { # set -> path relative to $ctx; reuses an existing snapshot of the same rev
  local set=$1 existing
  existing=$(find "$ctx/specs" -maxdepth 1 -name "*-$set-$rev.md" -printf 'specs/%f\n' | sort | head -1)
  if [[ -n $existing ]]; then echo "$existing"; return; fi
  local out files
  out="specs/$(date +%F)-$set-$rev.md"
  files=$(files_for "$set")
  for f in $files; do git -C "$repo" show "$rev:$f"; done > "$ctx/$out"
  [[ -s "$ctx/$out" ]] || { rm -f "$ctx/$out"; echo "spec-measure: empty snapshot for $set@$rev" >&2; exit 2; }
  chmod a-w "$ctx/$out"
  echo "$out"
}

cd "$ctx"
before=$(wc -l < corpus.jsonl 2>/dev/null || echo 0)
printf '%-34s %-8s %-7s %-13s %-8s %s\n' snapshot verdict d_pair ci95 clusters h_norm
for set in "${sets[@]}"; do
  spec=$(snapshot "$set")
  name=$(basename "$spec" .md)
  start=$(date +%s)
  rc=0
  tumanomir measure --format json "$spec" > "reports/$name.json" 2> "reports/$name.err" || rc=$?
  printf '%s\trc=%d\twall_sec=%d\tfinished=%s\n' "$name" "$rc" "$(($(date +%s) - start))" "$(date -Iseconds)" >> reports/runs.tsv
  if [[ $rc -eq 2 ]]; then
    printf '%-34s %s\n' "$name" "ERROR (rc=2): $(head -c 200 "reports/$name.err")"
    continue
  fi
  jq -r --arg n "$name" '.result as $r | $r.dispersion as $d |
    [$n, $r.d_pair_verdict, ($d.d_pair*100|round/100), "\($d.d_pair_ci_low*100|round/100)-\($d.d_pair_ci_high*100|round/100)",
     "\($d.clusters)/\($d.n)", ($d.h_norm*100|round/100)] | @tsv' "reports/$name.json" |
    awk -F'\t' '{ printf "%-34s %-8s %-7s %-13s %-8s %s\n", $1, $2, $3, $4, $5, $6 }'
  [[ -s "reports/$name.err" ]] && echo "  stderr: $(head -c 200 "reports/$name.err")"
done
echo "corpus.jsonl: $before -> $(wc -l < corpus.jsonl) rows (dedup by spec_hash+instrument)"
