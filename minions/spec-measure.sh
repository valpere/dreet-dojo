#!/usr/bin/env bash
# usage: minions/spec-measure.sh [git-rev] [req-uc|hld ...]
# Snapshot docs/ spec sets at <git-rev> (default HEAD) into ../context/tumanomir/specs/ (read-only),
# run `tumanomir measure` on each one sequentially with that dir's .tumanomir.yaml (corpus.enabled
# appends/dedups corpus.jsonl), keep the full report + stderr + runs.tsv, and print a summary table.
# Sets: req-uc (requirements.md + use-cases.md) and hld (hld.md). Default: both.
# All snapshots are built and checked before the first measurement; sequential on purpose
# (tumanomir v0.1 has no corpus file locking).
set -euo pipefail

die() { echo "spec-measure: $*" >&2; exit 2; }

files_for() {
  case "$1" in
    req-uc) echo "docs/requirements.md docs/use-cases.md" ;;
    hld) echo "docs/hld.md" ;;
    *) return 1 ;;
  esac
}

repo=$(git rev-parse --show-toplevel)
ctx="$repo/../context/tumanomir"

rev_arg=HEAD
if [[ $# -gt 0 ]] && ! files_for "$1" >/dev/null; then rev_arg=$1; shift; fi
full=$(git -C "$repo" rev-parse --verify --quiet "$rev_arg^{commit}") || die "not a commit: $rev_arg"
rev=${full:0:12}
sets=("$@")
[[ ${#sets[@]} -eq 0 ]] && sets=(req-uc hld)
for set in "${sets[@]}"; do files_for "$set" >/dev/null || die "unknown set '$set' (req-uc|hld)"; done
[[ -f "$ctx/.tumanomir.yaml" ]] || die "missing $ctx/.tumanomir.yaml"
mkdir -p "$ctx/specs" "$ctx/reports"

corpus_rows() { if [[ -f "$ctx/corpus.jsonl" ]]; then wc -l < "$ctx/corpus.jsonl"; else echo 0; fi; }

# find_snapshot <set>: existing snapshot whose rev suffix is a prefix of the full hash (any abbrev length).
find_snapshot() {
  local f r
  for f in "$ctx"/specs/*-"$1"-*.md; do
    [[ -e $f ]] || continue
    r=${f##*-"$1"-}; r=${r%.md}
    [[ ${#r} -ge 7 && $full == "$r"* ]] && { echo "specs/${f##*/}"; return 0; }
  done
  return 1
}

# make_snapshot <set>: writes the snapshot or dies; runs in the main shell (no $(...)) so errors abort.
make_snapshot() {
  local set=$1 out f
  out="specs/$(date +%F)-$set-$rev.md"
  for f in $(files_for "$set"); do
    git -C "$repo" cat-file -e "$full:$f" 2>/dev/null || die "$f does not exist at $rev"
  done
  : > "$ctx/$out"
  for f in $(files_for "$set"); do
    git -C "$repo" show "$full:$f" >> "$ctx/$out" || { rm -f "$ctx/$out"; die "git show $rev:$f failed"; }
    # separator only if the file lacks a trailing newline: keeps bytes (and spec_hash) identical to a plain concat
    [[ -z $(tail -c 1 "$ctx/$out") ]] || echo >> "$ctx/$out"
  done
  chmod a-w "$ctx/$out"
  snap=$out
}

declare -A spec_of
for set in "${sets[@]}"; do
  if existing=$(find_snapshot "$set"); then spec_of[$set]=$existing; else make_snapshot "$set"; spec_of[$set]=$snap; fi
done

cd "$ctx"
before=$(corpus_rows)
printf '%-36s %-8s %-7s %-13s %-8s %s\n' snapshot verdict d_pair ci95 clusters h_norm
for set in "${sets[@]}"; do
  spec=${spec_of[$set]}
  name=$(basename "$spec" .md)
  start=$(date +%s)
  rc=0
  tumanomir measure --format json "$spec" > "reports/$name.json" 2> "reports/$name.err" || rc=$?
  printf '%s\trc=%d\twall_sec=%d\tfinished=%s\n' "$name" "$rc" "$(($(date +%s) - start))" "$(date -Iseconds)" >> reports/runs.tsv
  row=$(jq -r --arg n "$name" '.result as $r | $r.dispersion as $d | select($d != null) |
    [$n, $r.d_pair_verdict, ($d.d_pair*100|round/100), "\($d.d_pair_ci_low*100|round/100)-\($d.d_pair_ci_high*100|round/100)",
     "\($d.clusters)/\($d.n)", ($d.h_norm*100|round/100)] | @tsv' "reports/$name.json" 2>/dev/null || true)
  if [[ -z $row ]]; then
    printf '%-36s %s\n' "$name" "ERROR (rc=$rc, no valid report): $(head -c 200 "reports/$name.err")"
    continue
  fi
  awk -F'\t' '{ printf "%-36s %-8s %-7s %-13s %-8s %s\n", $1, $2, $3, $4, $5, $6 }' <<<"$row"
  [[ -s "reports/$name.err" ]] && echo "  stderr: $(head -c 200 "reports/$name.err")"
done
echo "corpus.jsonl: $before -> $(corpus_rows) rows (dedup by spec_hash+instrument)"
