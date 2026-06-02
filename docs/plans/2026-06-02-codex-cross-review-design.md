# Codex cross-review design

**Date:** 2026-06-02
**Status:** Approved (brainstorm)

## Problem

The review cycle runs three Claude-agent phases per cycle — reviewer → adversary →
fixer — all writing to `.autopilot/feedback.json`. A single model family shares blind
spots; findings only Claude can't see (concurrency, certain edge cases) never surface.

## Goal

Add a **Codex** cross-review pass so a different model catches what Claude's
reviewer/adversary missed, and the existing fixer addresses those findings too — with
no fixer changes. Fit it into the repo's reserved agent-agnostic vision rather than
bolting on a codex special case.

## Flow

A new phase `05bx-codex` slots between the adversary and the fixer in each cycle:

```
05a-reviewer  (Claude)
05b-adversary (Claude)
05bx-codex    (Codex)   ← NEW, gated on codex availability
05c-fixer     (Claude)
```

By the time Codex runs, Claude's findings are already written and triaged. Codex reads
`feedback.json`, skips overlapping items, and appends only new findings with
`source: "codex"`. The unchanged fixer picks up every `open && severity != minor` item
regardless of source.

Codex reviews `git diff {{BASE_SHA}}..{{HEAD_SHA}}` — the same SHAs the reviewer and
adversary used this cycle (exported by `run_review_cycle`).

## Decisions (brainstorm)

| Question | Decision |
| --- | --- |
| Positioning | After adversary, before fixer — every cycle |
| Output contract | Codex writes `feedback.json` directly (same append protocol) |
| Genericity | Codex via `AUTOPILOT_CODEX_CMD`, modeled through an agent-profile abstraction |
| Default & missing binary | On by default; warn and skip if `codex` not on PATH |

## Agent-profile abstraction

Instead of positional params on `run_phase`, introduce the agent-profile concept the
README reserved (`AUTOPILOT_AGENT=claude|codex|aider`). Codex is its first consumer.

Kept **bash-3.2-safe** (no associative arrays) — two `case` dispatchers in `lib/agent.sh`:

```bash
agent_cmd_for() {     # profile → command
  case "$1" in
    cross) printf '%s' "$AUTOPILOT_CODEX_CMD" ;;
    *)     printf '%s' "$AUTOPILOT_AGENT_CMD" ;;
  esac
}
agent_filter_for() {  # profile → output filter
  case "$1" in
    cross) printf 'cat' ;;          # Codex native streaming, passthrough
    *)     printf 'agent_pretty' ;; # Claude stream-json
  esac
}
```

`run_phase` gains one optional arg — the profile (default primary) — keeping every
existing call unchanged:

```bash
run_phase 05bx-codex cross
```

Internally: `cmd=$(agent_cmd_for "$p")`, `filter=$(agent_filter_for "$p")`, pipe through
`"$filter"` instead of hardcoded `agent_pretty`. Those `case` arms are the future home of
per-agent defaults (command, filter, permission flag), so the abstraction is not throwaway.

**Config** (`config.sh` + `.autopilotrc.example`):

```bash
: "${AUTOPILOT_CODEX_CMD:=codex exec --full-auto}"
```

Empty value disables the pass even when the binary exists.

## Codex prompt (`prompts/05bx-codex.md`)

Mirrors the reviewer/adversary contract:

- Verify cwd is `{{WT}}`; exit if not.
- Read `.autopilot/feedback.json` first; do NOT re-flag any `open` item whose `detail`
  substantively matches — that's overlap.
- Review `git diff {{BASE_SHA}}..{{HEAD_SHA}}` with the standard checklist.
- Append each NEW finding to `.items`:
  - `id`: `c{{CYCLE}}-x-NNN` (`-x-` namespace; reviewer `-r-`, adversary `-a-`)
  - `source`: `"codex"`, `cycle`: `{{CYCLE}}`, `severity`/`category`/`title`/`detail`,
    `status:"open"`, `resolution_sha`/`resolution_note`: null
- Emphasis: "You are a second model. Prioritize blind spots a Claude-family reviewer
  would share — concurrency, edge cases, security — over restyling."

## Corruption guard (`run_review_cycle`)

Codex writes JSON directly, so a malformed write must not poison the fixer:

```bash
cp feedback.json feedback.json.bak       # before codex
run_phase 05bx-codex cross || return 1
jq empty feedback.json 2>/dev/null || {   # validate after
  log_err "Codex corrupted feedback.json; restoring"
  mv feedback.json.bak feedback.json
  return 1                                 # fail cycle → resumable
}
rm -f feedback.json.bak
```

On failure the cycle marker isn't set, so re-running re-enters at the codex phase with
the restored file. Claude's reviewer/adversary findings are already persisted, so nothing
is lost.

## Gating

```bash
run_phase 05a-reviewer  || return 1
run_phase 05b-adversary || return 1
if codex_available; then
  # backup → run_phase 05bx-codex cross → validate → cleanup
else
  log_warn "codex not found on PATH; skipping cross-review"
fi
run_phase 05c-fixer || return 1
```

`codex_available()` is true when `AUTOPILOT_CODEX_CMD` is non-empty AND its first word
resolves via `command -v`.

## Cost accounting

`state_add_cost` greps the log for Claude's `total_cost_usd`; Codex logs lack it. Confirm
it no-ops to `+0`; guard the call if it errors on a missing field. Codex's own cost is not
tracked (out of scope).

## Testing (bats-core)

- `agent_cmd_for` / `agent_filter_for` return correct values per profile.
- `codex_available`: true when binary present + var set; false when var empty; false when
  binary missing (stubbed PATH).
- Corruption guard: broken `feedback.json` → restore-from-`.bak` + non-zero return.
- `run_phase` honors the profile arg (filter dispatch).

Full reviewer→adversary→fixer integration remains untested (existing README gap); no new
cycle harness.

## Docs

- Add `AUTOPILOT_CODEX_CMD` to the README config table.
- Update the phase-order diagram to show `review×3` includes the codex pass.
- Note cross-review in "Modes."
