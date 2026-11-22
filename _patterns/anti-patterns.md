# Anti-Patterns — dreet-dojo

Existing explicit restrictions and observed failures, with sources and scope.
An observed failure is not itself a new prohibition.

## From CLAUDE.md
- ❌ Filling in TODO bodies in `internal/runner`, `internal/srs`, `internal/sandbox` on own initiative — human-owned; the project exists so Val writes them by hand
- ❌ Autocomplete, LSP, snippets, AI suggestions, `basicSetup`, `autocompletion` or `closeBrackets` in the editor — sterile-editor invariant (REQ-FR-05)
- ❌ Copying `solution.go` into `/work` or returning it from the API before `pass`/`giveup` — REQ-FR-07
- ❌ Claiming isolation of solutions, DB or network from exercise code — honest-user threat model (architecture.md §5.1, ADR-9)
- ❌ A new third-party Go dependency without a justification row in `docs/architecture.md` §4 — REQ-NFR-08
- ❌ An alpine runtime image — `-race` needs glibc + CGO (REQ-CON-02)
- ❌ A bracketed `[REQ-…]` tag outside a requirement definition — tumanomir counts it as a new, untraced requirement
- ❌ Wiring a minion into a hook, CI or the service — that makes it a utility

## Observed Failures (scoped evidence)
- `set -e`/`exit` inside `$(...)` did not stop `minions/spec-measure.sh`; a junk corpus row resulted (2026-11-22, see `mistakes.jsonl`). Scope: Bash scripts with side effects after validation.
- A changed concatenation separator altered snapshot bytes and so `spec_hash` (2026-11-22). Scope: inputs to content-hash dedup.

---
