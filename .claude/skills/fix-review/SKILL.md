---
name: fix-review
description: "Multi-model PR review with parallel fan-out. Primary: Ollama cloud (3 models). Automatic failover: Ollama local. Claude acts as Arbiter — confirms, escalates, or dismisses findings using vote count as confidence signal. Applies a single consolidated fix commit. Auto-merges (squash) when clean. Project-agnostic. Usage: /fix-review [PR-number]"
---

# Skill: /fix-review (parallel)
# Multi-model PR review (project-local)

Deployed copy for dreet-dojo of the canonical source `~/wrk/common_claude/skills/fix-review/`
(2026-11-22). Sync diff-first from canon; project config: `.claude/skills/fix-review/config.yaml`.

---

## OVERVIEW

Three model rounds run **in parallel**, then a single Claude arbiter
round adjudicates and applies the consolidated fix.

```
        ┌─→ Round 1 (model A)  ┐
diff ───┼─→ Round 2 (model B)  ┼─→ aggregate (dedupe + vote count)
        └─→ Round 3 (model C)  ┘
                                    ↓
                              Arbiter (Claude) — rules + ONE fix → commit → push
```

**Why parallel:**
- Wall time is `max(t₁, t₂, t₃)` instead of `t₁ + t₂ + t₃`.
- Three independent perspectives on the *same* diff (no caching effect from prior fixes).
- Vote count (1/3, 2/3, 3/3) is a strong confidence signal for the arbiter.
- One fix commit instead of four → cleaner PR history.

**Tradeoff vs. sequential:** no cascading feedback (R2 doesn't see what R1 fixed).
The arbiter handles dedup; in practice most "R2 reacted to R1's fix" cases were
just the second model lagging.

**Merge:** auto-merge (squash + delete branch) when the run is clean —
no fixes were reverted, the PR has no conflicts, and gates either passed
or only failed in layers this PR doesn't touch (diff-scope rule). When
something blocks merge, the skill asks the user once before acting.

---

## RUN COMPLETION CONTRACT (do not skip)

A run is **not** considered complete until **both** of these have happened
in this order, after Step 10 returns:

1. **Step 9 telemetry** — `telemetry.jsonl` has been appended with one
   row per model round + one arbiter row.
2. **Step 11 final summary** — printed to the user.

The auto-merge in Step 10 is **not** the end of the run. After it
returns (merged / left open / closed / asked-and-acted), control MUST
flow into Step 11 and print the summary. Do not stop after merge — the
human reads the summary, not the silence.

---

## STEP 0: Resolve PR + Load Config

```bash
# PR number — argument wins, else current branch's open PR
PR_NUMBER="${1:-$(gh pr view --json number --jq '.number' 2>/dev/null)}"
[ -z "$PR_NUMBER" ] && { echo "No PR found. Pass /fix-review <number>"; exit 1; }

BASE_BRANCH=$(gh pr view "$PR_NUMBER" --json baseRefName --jq '.baseRefName')
```

**Config** — project-local only (no user-wide install):

```bash
CONFIG=".claude/skills/fix-review/config.yaml"
```

Read fields from `$CONFIG` via `yq` (or grep/awk fallback):
- `provider` — `ollama` (the only supported value; anything else aborts)
- `reviewers.ollama.round_{1,2,3}.model` — primary models (cloud OR local)
- `reviewers.external_agents` — optional ordered list of `{tool, model}` —
  tier-2 failover via external agent CLIs, own free tiers (see lib/agents.sh)
- `reviewers.ollama_local.round_{1,2,3}.model` — optional local failover tier (tier 3)
- `ollama_api_url`
- `api_key_env` — optional; env var holding the Ollama key (default `OLLAMA_API_KEY`)
- `local_only` — optional `true`; project runs local models with no key (skips probe/failover)
- `post_summary_to_pr`
- `telemetry_enabled`
- `pricing.{model}.{input,output}` — for cost estimation

The exact reads referenced everywhere below as `$PROVIDER`/`$MODEL_R1`/
`$MODEL_R2`/`$MODEL_R3`/`$API_URL`:

```bash
PROVIDER=$(yq -r '.provider' "$CONFIG" 2>/dev/null)
API_URL=$(yq -r '.ollama_api_url' "$CONFIG" 2>/dev/null)
read_ollama_models() {
  local tier="$1"  # "ollama" (primary) or "ollama_local" — must match reviewers.* key in config.yaml
  M1=$(yq -r ".reviewers.${tier}.round_1.model // \"\"" "$CONFIG" 2>/dev/null)
  M2=$(yq -r ".reviewers.${tier}.round_2.model // \"\"" "$CONFIG" 2>/dev/null)
  M3=$(yq -r ".reviewers.${tier}.round_3.model // \"\"" "$CONFIG" 2>/dev/null)
}
read_ollama_models "ollama"
MODEL_R1="$M1"; MODEL_R2="$M2"; MODEL_R3="$M3"
```

(`read_ollama_models` is defined once here and reused later in this step
for the `ollama_local` tier — don't redefine it.)

**Validate provider + load API key:**

```bash
source .claude/skills/lib/env.sh
source .claude/skills/lib/rest.sh
source .claude/skills/lib/agents.sh

if [ "$PROVIDER" != "ollama" ]; then
  echo "ERROR: unsupported provider '$PROVIDER' in config.yaml — only 'ollama' is supported." >&2
  exit 1
fi

# Optional per-project override: api_key_env names a different env var
# (e.g. a project may use AI_PROVIDER_API_KEY instead of OLLAMA_API_KEY).
API_KEY_ENV=$(yq -r '.api_key_env // "OLLAMA_API_KEY"' "$CONFIG" 2>/dev/null || echo OLLAMA_API_KEY)
LOCAL_ONLY=$(yq -r '.local_only // false' "$CONFIG" 2>/dev/null || echo false)
load_env_key "$API_KEY_ENV" 2>/dev/null || true
API_KEY="${!API_KEY_ENV:-}"
# The key is optional: a signed-in local daemon (`ollama signin`) proxies `:cloud`
# models on localhost without auth. rest_post omits the Authorization header when
# the key is empty. The cloud probe below runs either way, so a daemon that cannot
# reach the cloud is caught there instead of producing a silent "clean" review.
[ -z "$API_KEY" ] && [ "$LOCAL_ONLY" != "true" ] && echo "note: no $API_KEY_ENV — using the signed-in local daemon for cloud models" >&2
```

A missing key is not fatal (ported from dreet-dojo, 2026-11-24; a keyless
`glm-5.3:cloud` call via the signed-in daemon verified live): the probe decides
whether the cloud tier works, and a failed probe with no failover tier still marks
`cloud_unavailable`, so a broken setup cannot pass silently.
When `local_only: true`, the probe and failover are skipped
and `reviewers.ollama` (local models) runs as primary.

**Provider probe + failover:**

After loading the key, probe the primary provider with a minimal call before
running the full review. If the probe fails (401, 402, "Insufficient credits",
"User not found", network error), fall back to Ollama automatically and
**always print a visible notice to the user**:

```bash
# Extract an Ollama error message from a response body.
# Handles {"error":"<string>"} and {"error":{"message|code":...}}; empty on success/no-error.
ollama_error() {
  printf '%s' "$1" | jq -r '
    (.error | if type == "string" then .
               elif type == "object" then (.message // .code // "")
               else "" end)' 2>/dev/null
}

probe_provider() {
  local url="$1" key="$2" model="$3"
  local probe_payload probe_resp
  probe_payload=$(jq -n --arg m "$model" \
    '{model:$m,messages:[{role:"user",content:"OK"}],stream:false,max_tokens:3}')
  probe_resp=$(REST_TIMEOUT=10 rest_post "$url" "$probe_payload" "$key") || probe_resp=""
  if [ -z "$probe_resp" ] || ! printf '%s' "$probe_resp" | jq -e . >/dev/null 2>&1; then
    echo "PROBE_ERROR: empty or non-JSON response"; return 1
  fi
  local err; err=$(ollama_error "$probe_resp")
  [ -n "$err" ] && { echo "PROBE_ERROR: $err"; return 1; }
  return 0
}

ACTIVE_PROVIDER="$PROVIDER"
ACTIVE_API_URL="$API_URL"
ACTIVE_KEY="$API_KEY"
ACTIVE_MODELS=("$MODEL_R1" "$MODEL_R2" "$MODEL_R3")
FAILOVER_TIER=""        # "" | "external_agents" | "ollama_local" | "cloud_unavailable"
FAILOVER_REASON=""

# read_ollama_models() was already defined above (used for the "ollama"
# primary tier) — reuse it here for "ollama_local", don't redefine it.
# A usable local failover tier requires all three rounds populated.
read_ollama_models "ollama_local"
LOCAL_TIER_EXISTS="no"
[ -n "$M1" ] && [ -n "$M2" ] && [ -n "$M3" ] && LOCAL_TIER_EXISTS="yes"

# Tier 2 — external agent CLIs (own free tiers, independent of Ollama
# quota). Optional, like ollama_local — absent config key means this tier
# is skipped and cloud failures fall straight to ollama_local, unchanged.
EXTERNAL_AGENTS_EXIST="no"
yq -e '.reviewers.external_agents' "$CONFIG" >/dev/null 2>&1 && EXTERNAL_AGENTS_EXIST="yes"

# Probe the primary whenever not local-only (key optional — see Step 0). If the
# probe fails, skip the doomed cloud call for every round (CLOUD_KNOWN_BAD)
# and let run_round()'s cascade decide per round which failover tier actually
# answers — external_agents (tier 2) tried before ollama_local (tier 3), same
# order as a per-round transient failure. Only mark cloud_unavailable
# immediately when NEITHER failover tier is configured at all, so the
# mandatory Step 11 notice still fires (rather than silently producing a
# 0-finding "clean" review).
CLOUD_KNOWN_BAD="no"
if [ "$LOCAL_ONLY" != "true" ]; then
  if ! probe_provider "$API_URL" "$API_KEY" "$MODEL_R2" 2>&1; then
    if [ "$EXTERNAL_AGENTS_EXIST" = "yes" ] || [ "$LOCAL_TIER_EXISTS" = "yes" ]; then
      echo "⚠️  FAILOVER: Ollama cloud unavailable — routing rounds through failover tiers"
      CLOUD_KNOWN_BAD="yes"; FAILOVER_REASON="cloud probe failed"
      # FAILOVER_TIER itself is decided per round in run_round()'s cascade
      # and reconciled after `wait` — see below.
    else
      echo "⚠️  WARNING: Ollama cloud unavailable and no failover tier configured — reviews will fail."
      FAILOVER_TIER="cloud_unavailable"; FAILOVER_REASON="cloud probe failed, no failover tier"
    fi
  fi
fi
```

Use `$ACTIVE_PROVIDER`, `$ACTIVE_API_URL`, `$ACTIVE_KEY`, and `$ACTIVE_MODELS`
everywhere from this point forward — **including the Step 3 `run_round` calls**
(pass `"${ACTIVE_MODELS[0]}"`, `[1]`, `[2]`; `run_round` reads `$ACTIVE_API_URL`
/ `$ACTIVE_KEY`). `$FAILOVER_TIER` is `""` (no failover), `"ollama_local"` (failed
over to local — probe or per-round), `"external_agents"` (a round fell back to
one of the tier-2 CLI tools — see Step 3), or `"cloud_unavailable"` (cloud down,
no failover tier). The probe block sets it in the parent shell; per-round
failover inside `run_round` runs in a subshell and can't, so it writes
`$RUN_DIR/round_${n}.failover` (containing either an `external_agents:<tool>`
value or a bare local-model name) and the parent sets `FAILOVER_TIER`
accordingly after `wait` (see Step 3 for the exact precedence).

**Ollama execution mode:** When `ACTIVE_PROVIDER=ollama`, run the three rounds
**sequentially** (not in parallel) and raise the per-call timeout to 300s.
Local and cloud LLMs can't reliably handle three concurrent large-model calls
without timing out.

In Step 11 final summary, the `### ⚠️ Provider failover` section must name the
tier that was used (`external_agents` or `ollama_local`) and the models, and
must also fire if any `$RUN_DIR/round_*.failover` file exists (a round fell
back mid-review).

---

## STEP 1: Detect Project Context

Project-agnosticism is built in. Detect:

### Test command

```bash
detect_test_cmd() {
  if [ -f Makefile ] && grep -qE '^(check|test):' Makefile; then
    if grep -qE '^check:' Makefile; then echo "make check"
    else echo "make test"; fi
  elif [ -f package.json ] && jq -e '.scripts.test' package.json >/dev/null 2>&1; then
    echo "npm test"
  elif [ -f Cargo.toml ];   then echo "cargo test"
  elif [ -f go.mod ];        then echo "go build ./... && go vet ./... && go test ./..."
  elif [ -f pyproject.toml ] || [ -f setup.py ] || [ -f setup.cfg ]; then
    if command -v pytest >/dev/null 2>&1; then echo "pytest -q"
    else echo "python -m pytest -q"; fi
  else echo ""; fi
}
TEST_CMD=$(detect_test_cmd)
```

If `TEST_CMD` is empty, ask the user once: "I can't detect the test command. What should I run?"

### Lint command (best-effort, not blocking)

```bash
detect_lint_cmd() {
  if [ -f Makefile ] && grep -qE '^lint:' Makefile; then echo "make lint"
  elif [ -f package.json ] && jq -e '.scripts.lint' package.json >/dev/null 2>&1; then echo "npm run lint"
  elif [ -f Cargo.toml ]; then echo "cargo clippy -- -D warnings"
  elif [ -f go.mod ];      then echo "golangci-lint run"
  elif [ -f pyproject.toml ] && command -v ruff >/dev/null 2>&1; then echo "ruff check ."
  else echo ""; fi
}
LINT_CMD=$(detect_lint_cmd)
```

### Project context (load-bearing rules to inject into the prompt)

In priority order, take the first that exists:
1. `.claude/context-essentials.md` — purpose-built for this case
2. `CLAUDE.md` (or `GEMINI.md`, `AGENTS.md`) — first ~150 lines, focus on "Key Design Decisions" / "Constraints" / "Banned patterns" sections
3. `README.md` — first ~80 lines as ambient context
4. (none) — generic prompt

```bash
load_project_context() {
  local f
  for f in .claude/context-essentials.md CLAUDE.md GEMINI.md AGENTS.md README.md; do
    if [ -f "$f" ]; then head -150 "$f"; return; fi
  done
  echo ""
}
PROJECT_CONTEXT=$(load_project_context)
```

### Telemetry destination

```bash
TELEMETRY_FILE=".claude/skills/fix-review/telemetry.jsonl"
```

---

## STEP 2: Build the Review Prompt

Single generic prompt, with `$PROJECT_CONTEXT` injected so each model can
apply project-specific rules. This is a fixed template (not read from
`$CONFIG`) — assign the block below verbatim to `$PROMPT_TEMPLATE`; Step 3
substitutes `{PROJECT_CONTEXT}`/`{DIFF}` into it to produce `$PROMPT`.

```
You are a senior code reviewer. Review the following git diff using the
Code Review Pyramid — evaluate from bottom to top, spending the most
attention on lower layers and least on higher ones:

  5 (top)  — Code style        → DO NOT FLAG. Formatters / linters handle this.
  4        — Tests             → Are critical paths covered? New branches tested?
  3        — Documentation     → Is complex logic explained? Public APIs documented?
  2        — Implementation    → Bugs, logic errors, null/nil deref, error handling,
                                 resource leaks, race conditions, security holes,
                                 missing context propagation, performance pitfalls.
  1 (base) — API / Architecture → Layer violations, contract drift, banned patterns,
                                  state-machine violations, hidden coupling.

== Project context ==
{PROJECT_CONTEXT}
== End project context ==

Apply the project rules above to layer 1 and layer 2 findings — they are
load-bearing for this codebase.

Return ONLY a JSON array — no prose, no markdown fences, just raw JSON.
Each item must have exactly these fields:
  "file"     — relative file path (string)
  "line"     — line number on the + side of the diff (integer)
  "layer"    — pyramid layer 1–4 (integer)
  "severity" — "error" | "warning" | "suggestion" (string)
  "body"     — clear description of the issue and how to fix it (string)

Severity guide:
  error      — must fix before merge (bug, security hole, layer-1 violation)
  warning    — should fix (missing test for critical path, undocumented public API)
  suggestion — nice to have

Do NOT flag: formatting, blank lines, import order (layer 5 — automated).
Do NOT flag code not present in this diff.
Do NOT propose architectural rewrites — focus on what the diff actually changes.

If there are no issues, return an empty array: []

Git diff:
---
{DIFF}
---
```

Substitute:
- `{PROJECT_CONTEXT}` — value of `$PROJECT_CONTEXT`
- `{DIFF}` — output of `gh pr diff ${PR_NUMBER}` (bypasses RTK hook interception)

---

## STEP 3: Fan Out — Three Models in Parallel

```bash
DIFF=$(gh pr diff "${PR_NUMBER}")
PROMPT=$(printf '%s' "$PROMPT_TEMPLATE" | sed "s|{PROJECT_CONTEXT}|$PROJECT_CONTEXT|" | sed "s|{DIFF}|$DIFF|")

# Output dir for this run
RUN_DIR=$(mktemp -d -t fix-review-XXXX)
START_MS=$(python3 -c "import time;print(int(time.time()*1000))" 2>/dev/null || echo $(($(date +%s) * 1000)))

# Fire all three in parallel — each writes its raw response to a file.
# System message enforces JSON-only output even when the diff contains markdown
# prose (spec/plan files) that confuses models into writing analysis text.
# Findings are capped and bodies kept short — see the empty-content note below.
REVIEW_SYSTEM_MSG="You are a senior code reviewer. Your entire response MUST be a raw JSON array — nothing else. Start with [ and end with ]. No prose, no markdown fences, no explanations before or after. Report at most 8 findings, most severe first; each body under 30 words. Do not include informational or 'no action needed' entries — only real issues. If there are no issues output exactly: []"
export REVIEW_SYSTEM_MSG

# Reasoning-capable models (deepseek, kimi, etc.) can burn their entire token
# budget on hidden thinking and return empty content on large diffs — use the
# *_no_think payload variant (think:false on Ollama, reasoning:{exclude:true}
# on OpenRouter) instead of the plain chat_payload_system.
run_round() {
  local n="$1" model="$2"
  local r_start r_end
  # Per-round `think` in config.yaml (reviewers.ollama.round_N.think): false
  # (default) | true (max effort) | a level string such as "low". For models
  # whose think:false output leaks reasoning prose instead of JSON (glm-5.3).
  # Thinking tokens eat num_predict: "low" fits the normal 4000 cap, true needs
  # ~16000. The empty-content retry keeps the same cap (a smaller one can only
  # fail the same way). Primary cloud tier only (not after a probe-time
  # failover to local models, whose ACTIVE_MODELS are different).
  local think=false think_val=false cap=4000 retry_cap=2000
  if [ "$FAILOVER_TIER" = "" ]; then
    think_val=$(yq -c ".reviewers.ollama.round_${n}.think // false" "$CONFIG" 2>/dev/null) \
      || { echo "warn: cannot read round_${n}.think (yq failed) — think disabled" >&2; think_val=false; }
    if [ "$think_val" != "false" ]; then
      # level string (e.g. "low"): normal cap, same-cap retry. Do not use "medium" —
      # measured to burn all 4000 tokens on thinking and return empty content.
      think=true; retry_cap=4000; [ "$think_val" = "true" ] && { cap=16000; retry_cap=16000; }
    fi
  fi
  r_start=$(python3 -c "import time;print(int(time.time()*1000))" 2>/dev/null || echo $(($(date +%s) * 1000)))
  local payload response active_provider active_url active_key err content
  active_provider="$ACTIVE_PROVIDER"
  active_url="$ACTIVE_API_URL"
  active_key="$ACTIVE_KEY"

  if [ "$CLOUD_KNOWN_BAD" = "yes" ]; then
    # Probe already confirmed cloud is down this run — skip the doomed call
    # for every round and go straight into the failover cascade below.
    err="cloud known unavailable (probe failed)"
    response='{"error":"cloud known unavailable"}'
  else
    if [ "$think" = true ]; then
      payload=$(chat_payload_system_think "$active_provider" "$model" "$REVIEW_SYSTEM_MSG" "$PROMPT" "$cap" "$think_val")
    else
      payload=$(chat_payload_system_no_think "$active_provider" "$model" "$REVIEW_SYSTEM_MSG" "$PROMPT" "$cap")
    fi
    response=$(rest_post_ollama "$active_url" "$payload" "$active_key") || response='{"error":"call failed"}'

    # Success but empty/whitespace content — the model burned its budget before
    # answering (err is empty here, so this isn't the API-error path below).
    # Retry once with a tighter cap before falling through to failover.
    err=$(ollama_error "$response")
    if [ -z "$err" ]; then
      content=$(chat_content "$active_provider" "$response")
      if [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]; then
        echo "warn: round ${n} (${model}) returned empty content — retrying once (cap ${retry_cap})" >&2
        if [ "$think" = true ]; then
          payload=$(chat_payload_system_think "$active_provider" "$model" "$REVIEW_SYSTEM_MSG" "$PROMPT" "$retry_cap" "$think_val")
        else
          payload=$(chat_payload_system_no_think "$active_provider" "$model" "$REVIEW_SYSTEM_MSG" "$PROMPT" "$retry_cap")
        fi
        response=$(rest_post_ollama "$active_url" "$payload" "$active_key") || response='{"error":"call failed"}'
        err=$(ollama_error "$response")
        # The retry can ALSO come back empty without an API-level error —
        # ollama_error alone won't catch that. Re-check content so this
        # doesn't silently skip tiers 2/3 and produce a false "clean"
        # 0-finding round (confirmed as a real gap 2026-07-30: err stayed
        # empty here even when the retry's content was still blank).
        if [ -z "$err" ]; then
          content=$(chat_content "$active_provider" "$response")
          if [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]; then
            err="empty content after retry"
          fi
        fi
      fi
    fi
  fi

  # Tier 2: external agent CLIs (own free tiers) — tried before Ollama local,
  # only if configured and the probe block hasn't already ruled out every
  # tier (FAILOVER_TIER="cloud_unavailable" means neither tier 2 nor 3 exists).
  if [ -n "$err" ] && [ "$FAILOVER_TIER" != "cloud_unavailable" ] && [ "$EXTERNAL_AGENTS_EXIST" = "yes" ]; then
    echo "warn: round ${n} error (${err}) — trying external_agents" >&2
    local prompt_file; prompt_file=$(mktemp)
    # Trap ensures the mktemp'd prompt_file is cleaned up on every exit path
    # (including the early `return 0` on success — without this the file leaks
    # under /tmp on every successful external_agents run; verified empirically).
    trap "rm -f '$prompt_file'" RETURN
    printf '%s\n\n%s' "$REVIEW_SYSTEM_MSG" "$PROMPT" > "$prompt_file"
    if try_external_agents "$n" "$prompt_file" "$CONFIG" "$RUN_DIR"; then
      r_end=$(python3 -c "import time;print(int(time.time()*1000))" 2>/dev/null || echo $(($(date +%s) * 1000)))
      # try_external_agents already wrote round_${n}.raw.json/.meta/.failover —
      # only fix up the timing half of .meta (it wrote duration "0").
      local winning_tool; winning_tool=$(head -1 "$RUN_DIR/round_${n}.meta")
      printf '%s\n%s' "$winning_tool" "$((r_end - r_start))" > "$RUN_DIR/round_${n}.meta"
      return 0
    fi
    err="all external_agents failed"
  fi

  # Tier 3: Ollama local — only if a full local tier is configured and
  # every tier above (cloud, external_agents) has been ruled out for this round.
  if [ -n "$err" ] && [ "$FAILOVER_TIER" != "cloud_unavailable" ] && [ "$LOCAL_TIER_EXISTS" = "yes" ]; then
    local local_model
    local_model=$(yq -r ".reviewers.ollama_local.round_${n}.model // \"\"" "$CONFIG" 2>/dev/null)
    echo "warn: round ${n} error (${err}) — trying Ollama local (${local_model})" >&2
    active_provider="ollama"
    active_key=""
    payload=$(chat_payload_system_no_think "$active_provider" "$local_model" "$REVIEW_SYSTEM_MSG" "$PROMPT" 4000)
    response=$(rest_post_ollama "$active_url" "$payload" "$active_key") || response='{"error":"ollama local failover failed"}'
    model="$local_model"
    # Subshell can't update the parent's FAILOVER_TIER — leave a marker for Step 11
    # containing the local model this round fell back to.
    printf '%s' "$local_model" > "$RUN_DIR/round_${n}.failover"
  fi

  r_end=$(python3 -c "import time;print(int(time.time()*1000))" 2>/dev/null || echo $(($(date +%s) * 1000)))
  printf '%s' "$response"   > "$RUN_DIR/round_${n}.raw.json"
  printf '%s\n%s' "$model"  "$((r_end - r_start))" > "$RUN_DIR/round_${n}.meta"
}

run_round 1 "${ACTIVE_MODELS[0]}" &
run_round 2 "${ACTIVE_MODELS[1]}" &
run_round 3 "${ACTIVE_MODELS[2]}" &
wait
# Surface any per-round failover to the parent shell for the Step 11 report.
# (Subshells can't update FAILOVER_TIER; they wrote $RUN_DIR/round_${n}.failover
# containing either "external_agents:<tool>" or a bare local model name.)
# Prefer reporting "external_agents" if ANY round used it — Step 11 still
# reads each marker individually for exact per-round detail regardless of
# this summary-level tier name.
if [ "$FAILOVER_TIER" = "" ] && ls "$RUN_DIR"/round_*.failover >/dev/null 2>&1; then
  if grep -l '^external_agents:' "$RUN_DIR"/round_*.failover >/dev/null 2>&1; then
    FAILOVER_TIER="external_agents"
  else
    FAILOVER_TIER="ollama_local"
  fi
  FAILOVER_REASON="per-round error mid-review (see round_*.failover)"
fi
```

> **Note on `&` + `wait`**: each background job runs in a subshell, so any
> exported variables from `source` calls remain visible. The functions
> defined above must be exported too — do `export -f run_round chat_payload chat_payload_system chat_payload_system_no_think chat_payload_system_think chat_content rest_post rest_post_ollama ollama_error ollama_payload ollama_payload_system ollama_payload_system_no_think ollama_payload_system_think ollama_content run_external_agent try_external_agents agent_cursor_agent agent_omp agent_codex agent_opencode agent_kilo` once before the parallel block, or inline the body of `run_round` in `bash -c '...' &` calls.
>
> **Failover chain**: `run_round()` cascades Ollama cloud (primary) → external
> agent CLIs (`reviewers.external_agents`, tier 2, tried in config order via
> `try_external_agents`) → Ollama local (tier 3) on per-round errors. Each
> tier is skipped if not configured (`EXTERNAL_AGENTS_EXIST`/`LOCAL_TIER_EXISTS`),
> and the whole cascade is skipped straight past cloud when `CLOUD_KNOWN_BAD=yes`
> (probe already confirmed cloud is down this run — avoids a doomed call per
> round). Primary models come from `reviewers.ollama.round_N.model` (via
> `$ACTIVE_MODELS`); local models from `reviewers.ollama_local.round_N.model`.
> A per-round failover writes `$RUN_DIR/round_${n}.failover` (the subshell
> can't update the parent's `FAILOVER_TIER`) — `external_agents:<tool>` or a
> bare local-model name; the parent reconciles `FAILOVER_TIER` after `wait`.
> If every tier fails, the round produces `[]` (0 findings).

---

## STEP 4: Parse Each Response → Findings Array

For each round 1, 2, 3:

```bash
parse_round() {
  local n="$1"
  local raw content
  raw=$(cat "$RUN_DIR/round_${n}.raw.json")
  content=$(chat_content "$PROVIDER" "$raw")
  # Strip code fences if model wrapped despite instructions.
  content=$(printf '%s' "$content" | sed -E 's/^```(json)?//; s/```$//')
  # Validate as JSON array.
  if ! echo "$content" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "[]" > "$RUN_DIR/round_${n}.findings.json"
    echo "warn: round ${n} response not a JSON array — treating as 0 findings" >&2
    return
  fi
  echo "$content" > "$RUN_DIR/round_${n}.findings.json"
}
parse_round 1; parse_round 2; parse_round 3
```

If a round returned prose: skip its findings (already 0). Don't retry —
parallel mode runs once.

---

## STEP 5: Aggregate — Dedupe + Vote Count

Merge all three rounds. Dedupe by `(file, line)`. For each unique location,
record:
- `votes` — how many models flagged it (1, 2, or 3)
- `models` — which models
- `body` — concatenation or longest body (longest is usually most informative)
- `worst_severity` — `error` > `warning` > `suggestion`
- `min_layer` — lowest pyramid layer mentioned (lower = more critical)

```bash
jq -s '
  # input: array of three arrays
  flatten
  | group_by(.file + ":" + (.line|tostring))
  | map({
      file:     .[0].file,
      line:     .[0].line,
      votes:    length,
      models:   [.[] | .model // ""],
      bodies:   [.[] | .body],
      body:     ([.[] | .body] | sort_by(length) | last),
      severity: ([.[] | .severity] | unique | (if any(. == "error") then "error" elif any(. == "warning") then "warning" else "suggestion" end)),
      layer:    ([.[] | .layer]    | min)
    })
  | sort_by(.layer, (if .severity == "error" then 0 elif .severity == "warning" then 1 else 2 end), -.votes)
' "$RUN_DIR/round_1.findings.json" "$RUN_DIR/round_2.findings.json" "$RUN_DIR/round_3.findings.json" \
  > "$RUN_DIR/aggregated.json"
```

> jq doesn't carry the `model` field through unless we add it during parse;
> for accurate `models[]`, tag findings with their model in Step 4 before
> aggregation: pipe each `findings.json` through `jq --arg m "$MODEL_RX" 'map(. + {model:$m})'` first.

The aggregated file is sorted critical-first: layer 1 errors found by 3/3 → layer 4 suggestions found by 1/3.

---

## STEP 6: Arbiter (Claude)

Read `$RUN_DIR/aggregated.json`. For each finding, rule:

| Ruling | When |
|---|---|
| **CONFIRM** | Real issue. Default for `votes ≥ 2` unless clearly false-positive. |
| **ESCALATE** | Real issue, more severe than tagged. |
| **DISMISS** | False positive, conflicts with project context, or layer-5 noise. Default for `votes == 1` unless obviously real. |
| **DEFER** | Real but out of scope. Log, don't fix. |

**Vote count is a confidence prior, not a verdict.** A 1-vote finding
that obviously points to a real bug should be confirmed. A 3-vote
finding that contradicts the project's load-bearing rules
(`.claude/context-essentials.md` / `CLAUDE.md`) should be dismissed
with reason.

**Independent scan**: also walk the full diff once and flag anything
all three models missed (rare but high-value).

**Apply CONFIRM + ESCALATE fixes** via the Edit tool. Minimal change
per fix; no opportunistic refactoring.

**Run gates** after fixes:
```bash
$TEST_CMD 2>&1 | tail -30
[ -n "$LINT_CMD" ] && $LINT_CMD 2>&1 | tail -20
```

### Diff-scope check before reverting

A gate failure does not automatically mean a fix is at fault. Before
reverting:

1. **Check what files this PR actually touches** —
   `gh pr diff "${PR_NUMBER}" --name-only`.
2. **Map failure to file types**:
   - Build / type-check / unit-test failure → caused only by changes to
     source files of that language (`.ts`/`.tsx`, `.go`, `.rs`, `.py` etc.).
   - Lint failure → same source files plus lint config.
   - Dependency CVE / vulnerability scan → only if dep manifest changed
     (`package.json`/`go.mod`/`Cargo.toml`/`pyproject.toml` + lock).
   - Migration / schema test → only if migration files changed.
3. **Decide**:
   - If the failing layer **is touched** by the diff → identify which fix
     is at fault, revert it via Edit, log as
     `reverted — caused $TEST_CMD failure`. Re-run gates.
   - If the failing layer **is NOT touched** by the diff → mark as
     **pre-existing**. Log in summary as
     `Pre-existing failure — not introduced by this PR. Continuing.`
     Do **not** revert. Do **not** silently pass the gate either —
     surface it explicitly so the human knows.

In particular, a documentation/config/skill-only PR (changes confined to
docs, `.claude/`, README, CI YAML) cannot cause source-build failures
by construction. Gates that fail in that case are always pre-existing.

Set `GATES_OK` for the merge step to read:

```bash
# After all gates run + reverts processed:
#   "yes" — passed clean OR every failure was in-scope-skipped as pre-existing
#   "no"  — at least one failing layer is touched by this PR's diff
GATES_OK=yes  # default optimistic; flip to "no" if any in-scope failure remains
```

---

## STEP 7: Commit + Push (single commit)

```bash
git add -A
# Don't commit telemetry if it's project-local
git restore --staged .claude/skills/fix-review/telemetry.jsonl 2>/dev/null || true

git commit -m "fix(pr#${PR_NUMBER}): address /fix-review findings

$(jq -r '.[] | select(.ruling=="CONFIRM" or .ruling=="ESCALATE") | "- \(.file):\(.line) — \(.body[0:80])"' "$RUN_DIR/arbiter.json" | head -20)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

git push
```

Skip the commit entirely if zero fixes applied. (Models may have all
agreed everything was fine.)

---

## STEP 8: Optional PR Summary Comment

If `post_summary_to_pr: true`:

```bash
gh pr comment "$PR_NUMBER" --body "$(cat <<EOF
<details>
<summary>/fix-review — ${PROVIDER} parallel pass · ${TOTAL_FINDINGS} findings · ${CONFIRMED} fixed · ${DISMISSED} dismissed</summary>

| File:Line | Votes | Layer | Sev | Ruling | Note |
|-----------|-------|-------|-----|--------|------|
${TABLE_ROWS}

Models: ${MODEL_R1}, ${MODEL_R2}, ${MODEL_R3}
Arbiter: Claude (vote count used as confidence prior)
</details>
EOF
)"
```

---

## STEP 9: Telemetry — JSONL Append

One entry per round + one arbiter entry, all in the same run.

**Round entry:**
```jsonc
{
  "timestamp": "2026-05-10T12:34:56Z",
  "pr_number": 42,
  "round_number": 1,
  "model": "glm-5.3",
  "provider": "ollama",
  "findings_count": 4,
  "prompt_tokens": null,
  "completion_tokens": null,
  "estimated_cost_usd": 0.0,
  "duration_ms": 8200
}
```

**Arbiter entry:**
```jsonc
{
  "timestamp": "2026-05-10T12:35:10Z",
  "pr_number": 42,
  "round_number": "arbiter",
  "model": "claude",
  "provider": "local",
  "confirmed": 5,
  "escalated": 1,
  "dismissed": 3,
  "added_new": 1,
  "parallel": true,
  "wall_time_ms": 9100
}
```

`wall_time_ms` is the parallel block duration (Step 3 START_MS → end of `wait`),
so you can compare against sum of round `duration_ms` to see the speedup.

`duration_ms` only appears on **round rows** and means pure model API
call time (HTTP request → response). The **arbiter row** has no
`duration_ms` field — local Claude has no API boundary, and the running
session does not reliably execute bash blocks meant to capture start/
end timestamps across multiple Bash tool invocations. Use
`wall_time_ms` (parallel block duration) as the timing signal in the
arbiter row.

**Append (fail-open):**
```bash
if [ "$TELEMETRY_ENABLED" = "true" ]; then
  jq -cn ... '{...}' >> "$TELEMETRY_FILE" 2>/dev/null || \
    echo "warn: telemetry write failed — continuing" >&2
fi
```

Cost estimation:
```bash
INPUT_PRICE=$(yq -r ".pricing[\"$MODEL\"].input  // \"null\"" "$CONFIG")
OUTPUT_PRICE=$(yq -r ".pricing[\"$MODEL\"].output // \"null\"" "$CONFIG")
if [ "$PROMPT_TOKENS" != "null" ] && [ "$INPUT_PRICE" != "null" ]; then
  COST=$(echo "scale=8; ($PROMPT_TOKENS / 1000000) * $INPUT_PRICE + ($COMPLETION_TOKENS / 1000000) * $OUTPUT_PRICE" | bc)
fi
```

---

## STEP 10: Auto-merge (or ask if blocked)

Default: **merge silently when clean**. Only prompt the user if something
blocks merge.

Conditions for clean auto-merge — all three must hold:

1. **No reverts** — `arbiter.json` has no `"reverted"` rulings.
2. **PR mergeable** — no merge conflicts.
3. **Gates green or pre-existing-skip** — Step 6 either passed cleanly,
   or every failing layer was confirmed pre-existing per the diff-scope
   rule (so `GATES_OK="yes"`).

```bash
MERGEABLE=$(gh pr view "$PR_NUMBER" --json mergeable --jq '.mergeable')
HAS_REVERT=$(jq -e 'any(.[]?; .ruling == "reverted")' "$RUN_DIR/arbiter.json" >/dev/null 2>&1 && echo "yes" || echo "no")
GATES_OK="${GATES_OK:-yes}"

BLOCKING=()
[ "$MERGEABLE" != "MERGEABLE" ] && BLOCKING+=("PR not mergeable: ${MERGEABLE}")
[ "$HAS_REVERT" = "yes" ]       && BLOCKING+=("one or more fixes reverted")
[ "$GATES_OK"  != "yes" ]       && BLOCKING+=("local gates failed in a layer this PR touches")

if [ ${#BLOCKING[@]} -eq 0 ]; then
  if ! gh pr merge "$PR_NUMBER" --auto --squash --delete-branch 2>/dev/null; then
    gh pr merge "$PR_NUMBER" --squash --delete-branch
  fi
  MERGE_STATUS="merged (squash)"
else
  cat <<EOM
PR #${PR_NUMBER} cannot auto-merge:
$(printf '  - %s\n' "${BLOCKING[@]}")

What should I do?
  1. Merge anyway (squash + delete branch)
  2. Leave open — you'll handle it manually
  3. Close PR — abandon
EOM
  # Wait for the user's choice and act:
  #   1 → gh pr merge "$PR_NUMBER" --squash --delete-branch ; MERGE_STATUS="merged (forced)"
  #   2 → MERGE_STATUS="left open"
  #   3 → gh pr close "$PR_NUMBER" --delete-branch ; MERGE_STATUS="closed"
fi
```

Notes:
- `--auto` requires "Allow auto-merge" in repo Settings → General. If
  unavailable the fallback `gh pr merge --squash` runs immediately.
- `--delete-branch` keeps the remote tidy.
- The user prompt fires only when truly necessary — clean runs are silent
  squash-merges.

**→ Now proceed to Step 11.** A successful merge does **not** end the
run — the user still needs the final summary. See *Run Completion
Contract* near the top of this skill.

---

## STEP 11: Final Summary (printed)

```
## /fix-review (parallel) — PR #${PR_NUMBER}

Provider: ${ACTIVE_PROVIDER}
Models:   ${MODEL_R1} | ${MODEL_R2} | ${MODEL_R3}
Wall time: ${WALL_TIME_MS} ms (vs sum-sequential ${SUM_SEQ_MS} ms — ${SPEEDUP}× speedup)

Aggregated findings: ${TOTAL}
  3/3 votes: ${THREE_VOTE} (high confidence)
  2/3 votes: ${TWO_VOTE}
  1/3 votes: ${ONE_VOTE}

Arbiter:
  Confirmed: ${CONFIRMED}
  Escalated: ${ESCALATED}
  Dismissed: ${DISMISSED}
  Deferred:  ${DEFERRED}
  Added new: ${ADDED_NEW}

Tests: ${TEST_RESULT}
Lint:  ${LINT_RESULT}

Commit: ${COMMIT_SHA}
PR:     ${PR_URL}
Merge:  ${MERGE_STATUS}        # merged | merged (forced) | left open | closed
Telemetry: ${TELEMETRY_FILE}
```

**Failover reporting (mandatory):** If `FAILOVER_TIER` is non-empty, always append a
`### ⚠️ Provider failover` section immediately after the summary block. Render it
for the failover kind — do NOT use one hardcoded "primary unavailable" line for
all cases (per-round failover means the cloud probe *succeeded*; only a round
failed transiently):

```
### ⚠️ Provider failover

Tier used: ${FAILOVER_TIER}   # "external_agents" = one or more rounds ran on
                              #   an external agent CLI (own free tier), not Ollama;
                              # "ollama_local" = failed over to Ollama local;
                              # "cloud_unavailable" = Ollama cloud down, NO failover tier
Reason: ${FAILOVER_REASON}
Primary models: ${ACTIVE_MODELS[0]} | ${ACTIVE_MODELS[1]} | ${ACTIVE_MODELS[2]}

Action: if "external_agents" — review ran on an external CLI tool's own free
tier (see per-round detail below for which one); check that tool's account if
this is unexpected. If "ollama_local" — review ran on (weaker, slower) local
models. If "cloud_unavailable" — the PR was NOT reviewed (0 findings); do NOT
merge blindly. Check `ollama serve` and `ollama signin` (or OLLAMA_API_KEY in .env.local), then
re-run.
```

If any `$RUN_DIR/round_*.failover` file exists (a round fell back mid-review while
the cloud probe succeeded, or `CLOUD_KNOWN_BAD` routed every round straight to
failover), additionally list each such round and what it fell back to — read
each marker file and disambiguate by its prefix:
- `external_agents:<tool>` → *"round N fell back to external agent `<tool>`"*
- anything else → *"round N fell back to Ollama local model `<value>`"* (the
  pre-existing local-model-name convention)

This is per-round detail, not necessarily a full cloud outage — phrase each
line accordingly (a round can fail transiently even when the cloud probe
itself succeeded).

---

## SWITCHING PROVIDERS

Config: edit `.claude/skills/fix-review/config.yaml` in the repo root.

Or ask: "switch fix-review to ollama cloud" / "switch fix-review to ollama local".

---

## DIFFERENCES FROM SEQUENTIAL VARIANT

If a project carries a sequential variant for specific architectural reasons,
keep it there — this canonical skill is the parallel fan-out. Differences:

| | Sequential (project) | Parallel (this) |
|--|--|--|
| Wall time | t₁+t₂+t₃ | max(t₁,t₂,t₃) |
| Commits per run | up to 4 (3 rounds + arbiter) | 1 |
| Cascading fixes | yes (R2 sees R1's fixes) | no |
| Vote count | implicit (last to flag wins) | explicit (1/3, 2/3, 3/3) |
| Loop detection | yes (80% overlap stop) | n/a — only one pass |
| Token cost | same | same |

When in doubt: **prefer this parallel variant** for clean PR history and
faster wall time. Use sequential only when you specifically want
cascading review (rare).
