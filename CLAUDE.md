# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Source of truth

`docs/` is the spec, written in Ukrainian. Read the relevant doc before changing behaviour or contracts:

- `docs/use-cases.md`: UC-01..07, including alternative flows and the HTTP codes each one returns.
- `docs/requirements.md`: FR, NFR, constraints, out of scope, and acceptance criteria AC-1..5.
- `docs/architecture.md`: components, dependency direction, stack, deployment topology, and ADR-1..8.
- `docs/hld.md`: module contracts (Go signatures), deck format, grading/SM-2/queue rules, flows, the
  HTTP API, `dreet serve` flags, deviations from the original ТЗ (§7), and open questions (§8).

The original design conversation lives in `../context/` and is history only. Where it disagrees with
`docs/`, `docs/` wins. When a change alters a contract, update `docs/` in the same PR.

Status: docs only, no code yet.

## What it is

**DreetDojo** is a "bare-wire coding dojo": a local-first, Dockerized trainer that restores hands-on
coding fluency. It uses timed micro-drills, checks them with a real compiler and tests, schedules
reviews with spaced repetition (adapted SM-2), and gives you a *sterile* editor with no autocomplete
and no AI. Go comes first; other languages are added as new `Runner` implementations.

Naming:

| What | Name |
| --- | --- |
| Brand | `DreetDojo` |
| Repo and Go module | `dreet-dojo` |
| Binary | `dreet` (`cmd/dreet`, `serve` / `validate`) |
| Docker service and user | `dreet`, UID 10001 |
| Database | `/data/dreet.db` |
| Starter deck | `decks/go-drills-01/` |

## Ownership boundary (STRICT)

The whole point of the project is that Val writes the core logic by hand.

- **HUMAN-OWNED:** `internal/runner/`, `internal/srs/`, `internal/sandbox/`.
  - Allowed for the agent: package stubs, exported interfaces and types, test harnesses, and
    reviewing Val's code when asked.
  - Never fill in TODO bodies there on your own initiative.
  - If a human-owned contract blocks you, propose the change in `docs/hld.md` §3 and wait for
    approval.
- **AGENT-OWNED:** `cmd/dreet/`, `internal/{api,deck,session,web,mock}/`, `web/`, `decks/`,
  `Dockerfile`, `docker-compose.yml`, `Makefile`.
- `--mock` wires the fakes from `internal/mock` in place of the three human-owned packages. This lets
  you check the API and the Docker image end to end before the real implementations exist.

## Architecture in one paragraph

`cmd/dreet` wires everything together. `internal/api` is a thin `net/http` transport over
`internal/session`, which owns the active attempt (server-side timer, counters, solution unlock).
Keep business logic out of `api`, because a stdio JSON-RPC transport is planned on top of `session`.

`session` orchestrates four packages through their interfaces:

| Package | Role |
| --- | --- |
| `deck` | Read-only cards from `/app/decks` |
| `sandbox` | `/work/<session_id>` on tmpfs; never contains `solution.go` |
| `runner` | `go test -race -json`, in its own process group, killed on timeout |
| `srs` | SQLite store plus the pure `EvaluateGrade` / `ScheduleSM2` |

`deck`, `srs` and `runner` are leaf packages. `internal/web` embeds `web/dist`.

## Hard invariants

- **Sterile editor.**
  - Use an explicit CodeMirror extension list. No `basicSetup`, `autocompletion`, `closeBrackets`,
    snippets, LSP or AI.
  - Keep only syntax highlighting, auto-indent, bracket matching, and backend diagnostics.
  - Keys: `Ctrl+S` run, `Alt+H` hint, `Alt+D` diff, `Alt+N` next.
- **Solution stays locked.** `solution.go` is never copied into `/work`, and is never returned by the
  API before the attempt ends in `pass` or `giveup` (403 until then).
- **Binary build.** `dreet` is built with `CGO_ENABLED=0`, with SQLite from `modernc.org/sqlite`.
  Routing is stdlib `net/http` only. Any new third-party Go dependency needs a justification row in
  `docs/architecture.md`.
- **Runtime image.** Use `golang:1.26-bookworm`, **never alpine**: `-race` needs glibc and CGO.
  Pre-warm `GOCACHE` at build time; it must stay writable via a named volume (ADR-2).
- **Compose.**
  - Publish only on `127.0.0.1:8787`.
  - Run as UID 10001 with `read_only`, `cap_drop: ALL`, `no-new-privileges`, `pids_limit: 128`,
    `mem_limit: 1g` and `cpus: 2.0`.
  - Mount `/work` and `/tmp` as tmpfs; `/tmp` must allow exec.
- **Go version.** Go 1.26+ for the core and for card `go.mod` files.

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

## Git

`main` is protected by a ruleset: PRs only, no force-push, no deletion. Work on `<type>-<slug>`
branches and squash-merge. No required CI checks yet.
