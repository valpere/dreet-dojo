# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

Pre-scaffold: no code yet and no `git init`. Everything below comes from the design
doc `../context/Відновлення_навичок_лайв-кодингу_на_Go.md`. Treat it as the spec. The
final ТЗ (MVP 1.0) section and the "Оновлений AGENTS.md" near the end of the doc win
over earlier drafts, which use the old names `drill-dojo` / `drill-engine` and older
contracts. Update this file once real commands and layout exist.

## What it is

**DreetDojo** ("bare-wire coding dojo") is a local-first, Dockerized trainer for
restoring hands-on coding fluency. It combines timed micro-drills, real compiler and
test checks, and spaced repetition (SRS), in a *sterile* editor with no autocomplete
and no AI. Go comes first. Other languages plug in as new `Runner` implementations.

Naming: brand `DreetDojo`; repo and Go module `dreet-dojo`; CLI binary `dreet`
(`cmd/dreet/main.go`, subcommands `serve` and `validate`); Docker service and user
`dreet` (UID 10001); DB `/data/dreet.db`; starter deck `decks/go-drills-01/`.

## Ownership boundary (STRICT)

The point of the project is that Val writes the core logic by hand.

- **HUMAN-OWNED:** `internal/runner/`, `internal/srs/`, `internal/sandbox/`. The agent
  may only create package stubs, exported interfaces and types, and test harnesses, or
  review Val's code when asked. Never fill in TODO bodies here on your own initiative.
  When a human-owned contract blocks you, propose the signature and wait for approval.
- **AGENT-OWNED:** `cmd/dreet/`, `internal/{api,deck,session,web}/`, `web/`,
  `decks/`, `Dockerfile`, `docker-compose.yml`, `Makefile`.
- Planned bootstrap: wire mocks of the three human-owned interfaces behind a `--mock`
  flag in `cmd/dreet`. This lets the HTTP API and Docker image be tested end to end
  before the real packages exist.

## Architecture

The design is a modular monolith in the Ports & Adapters style. It ships as one Go
binary inside one container.

- `internal/session` is the orchestrator. It owns the active attempt state on the
  server: `started_at`, `compile_errors`, `test_fails`, `hints_used` and
  `unlocked_solution`. It connects deck, srs, sandbox and runner.
- `internal/api` is only a thin `net/http` transport over `session`. Keep business
  logic out of HTTP, because a stdio JSON-RPC transport for editor plugins is planned
  on top of the same services.
- `internal/deck` loads cards from read-only `/app/decks` and validates them. It checks
  `meta.yaml` and the `prereq` graph for cycles.
- `internal/sandbox` keeps one `/work/<session_id>` per attempt on tmpfs. It copies
  `go.mod`, `kata.go` and `kata_test.go` there, **never `solution.go`**. It overwrites
  only the `EntryFile` atomically and blocks path traversal. It also builds the unified
  diff.
- `internal/runner` defines `Runner{Lang(); Check(ctx, workDir)}`. `GoRunner` runs
  `go test -race -json -count=1 -timeout=5s ./...` in its own process group
  (`Setpgid`) and SIGKILLs `-pgid` on timeout. It maps the JSON event stream to one of
  the statuses `pass`, `compile_error`, `test_fail` or `timeout`, plus diagnostics
  `{file,line,col,severity,message}`. A `DATA RACE` counts as `test_fail`.
- `internal/srs` stores state in SQLite (`card_state` and `attempts`; WAL,
  `foreign_keys=ON`, `busy_timeout=5000`; the state update and the attempt row go in
  one transaction). `scheduler.go` (`EvaluateGrade` and `ScheduleSM2`) has no DB
  dependency.
  - Grade 1–4 is derived from telemetry, never chosen by the user.
  - Scheduling is an adapted SM-2 with intervals starting at 1→3 days, EF limited to
    [1.3, 3.0], a 60-day maximum and ±5% jitter for intervals of 4 days or more.
  - Queue order: overdue cards first, then new cards in `sort_order`, where a new card
    is gated until its prereq has `reps >= 1`, with a `new_per_day` limit (default 3).
  - Exact tables are in the design doc.
- `internal/web` serves the `//go:embed dist/*` SPA built from `web/` (Vite, TypeScript,
  CodeMirror 6 with `lang-go`, `merge` and `lint`; no React or other heavy frameworks).

Card layout is `decks/<deck>/<card-id>/{meta.yaml, prompt.md, go.mod, kata.go,
kata_test.go, solution.go}`. Formats are `cloze`, `spec`, `progressive` (chained
through `prereq`), `bugfix` and `skeleton`. Invariant: the stub fails the tests (or
fails to compile, for skeleton cards) and the solution passes under `-race`.

HTTP API (`/api`; errors use the shape `{"error":{"code","message"}}`):
- `GET health`
- `GET session/next[?ahead=true]` (204 when nothing is due)
- `POST attempt/run`
- `POST attempt/hint`
- `POST attempt/giveup`
- `GET attempt/diff` (403 until the attempt is `pass` or `giveup`)
- `GET stats`

Field-level details are in the design doc §4.4.

## Hard invariants

- **Sterile editor:** no autocomplete, LSP, snippets or AI suggestions. Keep only
  syntax highlighting, auto-indent, bracket matching, inline runner diagnostics, and
  the keys `Ctrl+S` (run), `Alt+H` (hint), `Alt+D` (diff) and `Alt+N` (next).
- `solution.go` must never be reachable from the sandbox or the API before the attempt
  is finished.
- The `dreet` binary is built with `CGO_ENABLED=0` (`modernc.org/sqlite`). Use stdlib
  `net/http` routing, and add no third-party Go dependencies without explaining why
  stdlib is not enough.
- Runtime image: `golang:*-bookworm`, **never alpine**, because `-race` needs glibc and
  CGO when tests run. Pre-warm `GOCACHE=/var/cache/go-build` with `go test -race` on
  stdlib packages at build time, to hit the ≤500 ms check target.
- Compose settings: bind only `127.0.0.1:8787`; non-root UID 10001; `read_only: true`;
  `cap_drop: ALL`; `no-new-privileges`; `pids_limit: 128`; `mem_limit: 1g`;
  `cpus: 2.0`. `/work` and `/tmp` are tmpfs, with exec allowed on `/tmp`. Mount
  `./decks:/app/decks:ro` and `./data:/data`.
- Go version: the spec says 1.24, but Val's global convention is Go 1.26+. Use 1.26
  for `go.mod` and the images unless Val says otherwise.

## Verification (before reporting done)

These commands are planned and will be confirmed once the scaffold exists:

```bash
go vet ./... && go test -race ./...
go test -race -run TestName ./internal/<pkg>/      # single test
npm --prefix web run build && go build ./cmd/dreet # frontend must embed cleanly
dreet validate --decks ./decks                     # required after any deck/card change
docker compose up --build                          # after Dockerfile/compose changes; check GET /api/health
```

Open the UI with `chromium --app=http://127.0.0.1:8787`.
