#!/usr/bin/env bash
# usage: minions/fix-review-rounds.sh <PR>
# Run /fix-review Steps 0-5 for a PR exactly as written in .claude/skills/fix-review/SKILL.md: the bash blocks are
# extracted from the skill at run time (so the skill stays the single source), the three rounds run sequentially
# (Ollama mode), then findings are tagged by model and aggregated. Prints the run dir, per-round timing/counts and
# the aggregated findings as JSON lines. Arbiter, fixes, commit, telemetry and merge stay with the agent.
set -euo pipefail

pr=${1:?usage: minions/fix-review-rounds.sh <PR>}
[[ $pr =~ ^[0-9]+$ ]] || { echo "fix-review-rounds: PR must be a number" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
F=.claude/skills/fix-review/SKILL.md
[[ -f $F ]] || { echo "fix-review-rounds: $F not found" >&2; exit 2; }

# blk RE: print a fenced bash block body starting at the first line matching RE, up to the closing fence.
blk() { awk -v re="$1" '$0 ~ re {p=1} p && /^```$/ {exit} p' "$F"; }
need() { [[ -n $2 ]] || { echo "fix-review-rounds: block '$1' not found in $F" >&2; exit 2; }; printf '%s\n' "$2"; }

run_dir=$(mktemp -d -t fix-review-XXXX)
script="$run_dir/rounds.sh"
{
  echo "set -u; PR_NUMBER=$pr; CONFIG=.claude/skills/fix-review/config.yaml"
  need config "$(blk '^PROVIDER=[$][(]yq')"
  need key "$(blk '^source [.]claude/skills/lib/env[.]sh')"
  need probe "$(blk '^ollama_error[(][)] [{]')"
  need context "$(blk '^load_project_context[(][)] [{]')"
  echo "PROMPT_TEMPLATE=\$(cat <<'FIXREVIEW_TPL'"
  need template "$(awk '/^## STEP 2/ {s=1} s && /^```$/ {c++; if (c == 2) exit; next} s && c == 1' "$F")"
  echo 'FIXREVIEW_TPL'
  echo ')'
  # Bash substitution instead of the skill's sed: the diff contains | and & that break sed replacement.
  echo 'DIFF=$(gh pr diff "$PR_NUMBER"); PROMPT=${PROMPT_TEMPLATE/\{PROJECT_CONTEXT\}/$PROJECT_CONTEXT}; PROMPT=${PROMPT/\{DIFF\}/$DIFF}'
  echo "RUN_DIR=$run_dir; START_MS=\$((\$(date +%s%N)/1000000))"
  need run_round "$(awk '/^REVIEW_SYSTEM_MSG=/ {p=1} p && /^run_round 1 / {exit} p' "$F")"
  echo 'run_round 1 "${ACTIVE_MODELS[0]}"; run_round 2 "${ACTIVE_MODELS[1]}"; run_round 3 "${ACTIVE_MODELS[2]}"'
  echo 'echo "WALL_MS=$(( $(date +%s%N)/1000000 - START_MS ))"'
  echo 'for f in "$RUN_DIR"/round_*.failover; do [ -f "$f" ] && echo "FAILOVER $(basename "$f"): $(cat "$f")"; done'
  echo '[ -n "$FAILOVER_TIER" ] && echo "FAILOVER_TIER=$FAILOVER_TIER ($FAILOVER_REASON)"'
  need parse "$(blk '^parse_round[(][)] [{]')"
  echo 'for n in 1 2 3; do m=$(head -1 "$RUN_DIR/round_$n.meta"); jq --arg m "$m" "map(. + {model:\$m})" "$RUN_DIR/round_$n.findings.json" > "$RUN_DIR/t" && mv "$RUN_DIR/t" "$RUN_DIR/round_$n.findings.json"; echo "round $n $m $(tail -1 "$RUN_DIR/round_$n.meta")ms findings=$(jq length "$RUN_DIR/round_$n.findings.json")"; done'
  need aggregate "$(awk '/^## STEP 5/ {s=1} s && /^jq -s/ {p=1} p {print} p && /aggregated\.json"$/ {exit}' "$F")"
  echo 'jq -c ".[] | {file,line,votes,severity,layer,models,body}" "$RUN_DIR/aggregated.json"'
} > "$script"
bash -n "$script" || { echo "fix-review-rounds: assembled script has a syntax error: $script" >&2; exit 2; }
echo "RUN_DIR=$run_dir"
bash "$script"
