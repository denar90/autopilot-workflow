# Codex Cross-Review Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a Codex cross-review phase between the adversary and fixer in each review cycle so a second model catches what Claude's reviewers missed, with findings flowing into the existing `feedback.json` → fixer path unchanged.

**Architecture:** Introduce a lightweight, bash-3.2-safe "agent profile" abstraction (two `case` dispatchers) so the cross-reviewer is the first consumer of the README's reserved `AUTOPILOT_AGENT=claude|codex|aider` vision rather than a codex special-case. `run_phase` gains an optional profile arg. `run_review_cycle` inserts a gated codex phase with a feedback.json corruption guard.

**Tech Stack:** Bash 3.2 (no associative arrays), jq, bats-core, shellcheck. Codex CLI (`codex exec --full-auto`) as the cross-review agent.

---

## Design reference

Full design: `docs/plans/2026-06-02-codex-cross-review-design.md`.

**Constraints discovered during planning:**
- `lib/state.sh::state_add_cost` already no-ops when a log lacks a `"type":"result"` event (state.sh:39-41). Codex logs have no such event → cost is silently skipped. **No cost guard task needed.**
- `lib/ui.sh::log_warn` already exists (ui.sh:14).
- Tests live in `tests/test_*.bats`, `load helpers`, use `LIB_DIR="$(...)/lib"`.
- `run_phase` (agent.sh:61-85) currently hardcodes `$AUTOPILOT_AGENT_CMD` and pipes through `agent_pretty`.
- `run_review_cycle` (review.sh:5-24) runs `05a-reviewer` → `05b-adversary` → `05c-fixer`.

**Where new functions live:**
- `agent_cmd_for`, `agent_filter_for`, `codex_available` → `lib/agent.sh`
- `feedback_restore_if_corrupt` → `lib/review.sh`

---

## Task 1: Add `AUTOPILOT_CODEX_CMD` config default

**Files:**
- Modify: `lib/config.sh:4-22` (inside `config_load`, add default + export)
- Modify: `.autopilotrc.example` (document the var)
- Test: `tests/test_config.bats`

**Step 1: Write the failing test**

Add to `tests/test_config.bats`:

```bash
@test "config_load defaults AUTOPILOT_CODEX_CMD to a codex invocation" {
  config_load
  [ "${AUTOPILOT_CODEX_CMD}" = "codex exec --full-auto" ]
}

@test "config_load preserves caller-set AUTOPILOT_CODEX_CMD" {
  export AUTOPILOT_CODEX_CMD="codex --custom"
  config_load
  [ "${AUTOPILOT_CODEX_CMD}" = "codex --custom" ]
}
```

**Step 2: Run to verify it fails**

Run: `bats tests/test_config.bats -f CODEX`
Expected: FAIL — `AUTOPILOT_CODEX_CMD` is empty.

**Step 3: Implement**

In `lib/config.sh`, add after the `AUTOPILOT_AGENT_CMD` default line (config.sh:7):

```bash
  : "${AUTOPILOT_CODEX_CMD:=codex exec --full-auto}"
```

Add `AUTOPILOT_CODEX_CMD` to the `export` list (config.sh:19-21):

```bash
  export AUTOPILOT_WORKTREE_BASE AUTOPILOT_MODEL AUTOPILOT_AGENT_CMD \
         AUTOPILOT_CODEX_CMD \
         AUTOPILOT_SETUP_CMD AUTOPILOT_VERIFY_CMD AUTOPILOT_SYMLINKS \
         AUTOPILOT_MODE AUTOPILOT_DEFAULT_ACTION
```

In `.autopilotrc.example`, add after the `AUTOPILOT_AGENT_CMD` block:

```bash
# Cross-review agent (a second model that reviews after Claude's reviewer/adversary,
# before the fixer). Runs every review cycle. Stdin = prompt. Leave empty to disable
# even when codex is installed. Skipped automatically if the binary isn't on PATH.
: "${AUTOPILOT_CODEX_CMD:=codex exec --full-auto}"
```

**Step 4: Run to verify it passes**

Run: `bats tests/test_config.bats`
Expected: PASS (all tests).

**Step 5: Commit**

```bash
git add lib/config.sh .autopilotrc.example tests/test_config.bats
git commit -m "feat(config): add AUTOPILOT_CODEX_CMD for cross-review"
```

---

## Task 2: Agent-profile dispatchers (`agent_cmd_for`, `agent_filter_for`)

**Files:**
- Modify: `lib/agent.sh` (add two functions near the top, after the header comment)
- Test: `tests/test_agent.bats`

**Step 1: Write the failing test**

Add to `tests/test_agent.bats`:

```bash
@test "agent_cmd_for primary returns AUTOPILOT_AGENT_CMD" {
  export AUTOPILOT_AGENT_CMD="claude -p"
  export AUTOPILOT_CODEX_CMD="codex exec"
  [ "$(agent_cmd_for primary)" = "claude -p" ]
}

@test "agent_cmd_for cross returns AUTOPILOT_CODEX_CMD" {
  export AUTOPILOT_AGENT_CMD="claude -p"
  export AUTOPILOT_CODEX_CMD="codex exec"
  [ "$(agent_cmd_for cross)" = "codex exec" ]
}

@test "agent_cmd_for unknown profile falls back to primary" {
  export AUTOPILOT_AGENT_CMD="claude -p"
  [ "$(agent_cmd_for whatever)" = "claude -p" ]
}

@test "agent_filter_for primary returns agent_pretty" {
  [ "$(agent_filter_for primary)" = "agent_pretty" ]
}

@test "agent_filter_for cross returns cat" {
  [ "$(agent_filter_for cross)" = "cat" ]
}
```

**Step 2: Run to verify it fails**

Run: `bats tests/test_agent.bats -f agent_cmd_for`
Expected: FAIL — `command not found: agent_cmd_for`.

**Step 3: Implement**

In `lib/agent.sh`, after the header comment (agent.sh:2), add:

```bash
# Agent profiles: resolve a command + output filter by profile name. This is the
# bash-3.2-safe seam the README's reserved AUTOPILOT_AGENT=claude|codex|aider work
# will grow into (no associative arrays). Today: "primary" (Claude) and "cross" (Codex).
agent_cmd_for() {
  case "$1" in
    cross) printf '%s' "$AUTOPILOT_CODEX_CMD" ;;
    *)     printf '%s' "$AUTOPILOT_AGENT_CMD" ;;
  esac
}

agent_filter_for() {
  case "$1" in
    cross) printf 'cat' ;;          # Codex streams plain text; pass through verbatim
    *)     printf 'agent_pretty' ;; # Claude stream-json → human-readable
  esac
}
```

**Step 4: Run to verify it passes**

Run: `bats tests/test_agent.bats`
Expected: PASS (existing + 5 new).

**Step 5: Commit**

```bash
git add lib/agent.sh tests/test_agent.bats
git commit -m "feat(agent): add agent-profile command/filter dispatchers"
```

---

## Task 3: `codex_available` gate

**Files:**
- Modify: `lib/agent.sh` (add function after the profile dispatchers)
- Test: `tests/test_agent.bats`

**Step 1: Write the failing test**

Add to `tests/test_agent.bats`:

```bash
@test "codex_available false when AUTOPILOT_CODEX_CMD empty" {
  export AUTOPILOT_CODEX_CMD=""
  run codex_available
  [ "$status" -ne 0 ]
}

@test "codex_available false when binary not on PATH" {
  export AUTOPILOT_CODEX_CMD="definitely-not-a-real-binary-xyz exec"
  run codex_available
  [ "$status" -ne 0 ]
}

@test "codex_available true when first word resolves on PATH" {
  # 'env' is a coreutils binary present on every PATH
  export AUTOPILOT_CODEX_CMD="env exec --full-auto"
  run codex_available
  [ "$status" -eq 0 ]
}
```

**Step 2: Run to verify it fails**

Run: `bats tests/test_agent.bats -f codex_available`
Expected: FAIL — `command not found: codex_available`.

**Step 3: Implement**

In `lib/agent.sh`, after `agent_filter_for`, add:

```bash
# codex_available: true when the cross-review command is configured AND its binary
# resolves on PATH. Empty AUTOPILOT_CODEX_CMD disables the pass even if codex exists.
codex_available() {
  [[ -n "${AUTOPILOT_CODEX_CMD:-}" ]] || return 1
  local first="${AUTOPILOT_CODEX_CMD%% *}"
  command -v "$first" >/dev/null 2>&1
}
```

**Step 4: Run to verify it passes**

Run: `bats tests/test_agent.bats`
Expected: PASS.

**Step 5: Commit**

```bash
git add lib/agent.sh tests/test_agent.bats
git commit -m "feat(agent): add codex_available gate"
```

---

## Task 4: Make `run_phase` profile-aware

**Files:**
- Modify: `lib/agent.sh:61-85` (`run_phase`)
- Test: `tests/test_agent.bats`

**Step 1: Write the failing test**

This test proves the filter is dispatched by profile: feed a prompt that *is* a Claude stream-json line, use `cat` as the fake agent (echoes the prompt back). Primary profile runs it through `agent_pretty` (extracts the text, drops raw JSON); cross profile runs through `cat` (raw JSON survives).

Add to `tests/test_agent.bats`:

```bash
@test "run_phase dispatches filter by profile" {
  TMP="$(mktemp -d)"
  export AUTOPILOT_ROOT="$TMP/root"
  export WT="$TMP/wt"
  mkdir -p "$AUTOPILOT_ROOT/prompts" "$WT/.autopilot"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"HELLO"}]}}' \
    > "$AUTOPILOT_ROOT/prompts/smoke.md"
  export AUTOPILOT_AGENT_CMD="cat"
  export AUTOPILOT_CODEX_CMD="cat"

  out_primary="$(run_phase smoke primary | sed $'s/\x1b\\[[0-9;]*m//g')"
  out_cross="$(run_phase smoke cross | sed $'s/\x1b\\[[0-9;]*m//g')"

  # agent_pretty extracts the text and drops the raw JSON envelope
  [[ "$out_primary" == *"HELLO"* ]]
  [[ "$out_primary" != *'"type":"assistant"'* ]]
  # cat passes the raw stream-json line through verbatim
  [[ "$out_cross" == *'"type":"assistant"'* ]]

  rm -rf "$TMP"
}
```

> Note: `run_phase` calls `state_add_cost`, which is a no-op here (the `cat` output has no `"type":"result"` event, so it returns before touching any state file). `test_agent.bats` already sources `ui.sh` and `agent.sh` in `setup()`, which is all `run_phase` needs.

**Step 2: Run to verify it fails**

Run: `bats tests/test_agent.bats -f "dispatches filter"`
Expected: FAIL — current `run_phase` ignores a second arg and always uses `agent_pretty`, so `out_cross` won't contain the raw JSON.

**Step 3: Implement**

Edit `lib/agent.sh` `run_phase`. Change the signature/locals (agent.sh:61-66):

```bash
run_phase() {
  local name="$1"
  local profile="${2:-primary}"
  local cmd filter
  cmd="$(agent_cmd_for "$profile")"
  filter="$(agent_filter_for "$profile")"
  local repo_root="${AUTOPILOT_ROOT}"
  local tmpl="${repo_root}/prompts/${name}.md"
  local rendered="${WT}/.autopilot/prompts/${name}.md"
  local logf="${WT}/.autopilot/logs/${name}.log"
```

Change the log line (agent.sh:71) to use the resolved command:

```bash
  log_info "Phase ${name} → ${cmd%% *}"
```

Change the invocation block (agent.sh:74-77) from `eval $AUTOPILOT_AGENT_CMD` / `agent_pretty` to the resolved command and filter:

```bash
  # Full raw output goes to log; terminal sees only the profile's filtered view.
  ( cd "$WT" && eval "$cmd" ) < "$rendered" 2>&1 \
    | tee "$logf" \
    | "$filter"
```

(Removes the need for the `# shellcheck disable=SC2086` comment on agent.sh:74 — `eval "$cmd"` is quoted. Delete that disable comment.)

**Step 4: Run to verify it passes**

Run: `bats tests/test_agent.bats`
Expected: PASS (existing + new).

**Step 5: Verify no regressions across the suite**

Run: `make test`
Expected: All bats files pass.

**Step 6: Commit**

```bash
git add lib/agent.sh tests/test_agent.bats
git commit -m "feat(agent): make run_phase profile-aware"
```

---

## Task 5: `feedback_restore_if_corrupt` guard

**Files:**
- Create: `tests/test_review.bats`
- Modify: `lib/review.sh` (add function above `run_review_cycle`)

**Step 1: Write the failing test**

Create `tests/test_review.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/ui.sh"
  source "$LIB_DIR/review.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

@test "feedback_restore_if_corrupt leaves valid JSON untouched, returns 0" {
  echo '{"items":[{"id":"c1-r-001"}]}' > "$TMP/fb.json"
  cp "$TMP/fb.json" "$TMP/fb.json.bak"
  run feedback_restore_if_corrupt "$TMP/fb.json" "$TMP/fb.json.bak"
  [ "$status" -eq 0 ]
  run jq -r '.items[0].id' "$TMP/fb.json"
  [ "$output" = "c1-r-001" ]
}

@test "feedback_restore_if_corrupt restores backup on invalid JSON, returns 1" {
  echo '{"items":[{"id":"good"}]}' > "$TMP/fb.json.bak"
  printf '{ this is not valid json' > "$TMP/fb.json"
  run feedback_restore_if_corrupt "$TMP/fb.json" "$TMP/fb.json.bak"
  [ "$status" -eq 1 ]
  run jq -r '.items[0].id' "$TMP/fb.json"
  [ "$output" = "good" ]
}
```

**Step 2: Run to verify it fails**

Run: `bats tests/test_review.bats`
Expected: FAIL — `command not found: feedback_restore_if_corrupt`.

**Step 3: Implement**

In `lib/review.sh`, add above `run_review_cycle` (review.sh:5):

```bash
# feedback_restore_if_corrupt <file> <backup>
# Codex writes feedback.json directly; a malformed write must not poison the fixer.
# If <file> is not valid JSON, restore <backup> over it and return 1. Otherwise 0.
feedback_restore_if_corrupt() {
  local f="$1" bak="$2"
  if jq empty "$f" >/dev/null 2>&1; then
    return 0
  fi
  log_err "Codex corrupted ${f}; restoring from backup"
  mv "$bak" "$f"
  return 1
}
```

**Step 4: Run to verify it passes**

Run: `bats tests/test_review.bats`
Expected: PASS.

**Step 5: Commit**

```bash
git add lib/review.sh tests/test_review.bats
git commit -m "feat(review): add feedback.json corruption guard"
```

---

## Task 6: Codex review prompt

**Files:**
- Create: `prompts/05bx-codex.md`

**Step 1: Create the prompt**

Modeled on `prompts/05a-reviewer.md` and `05b-adversary.md`. Write `prompts/05bx-codex.md`:

```markdown
You are the CROSS-REVIEWER (a second model, Codex) for ticket {{TICKET}}, cycle {{CYCLE}}.

Verify cwd is `{{WT}}`. If not, exit.

Tools: read-only inspection (no source edits, no git mutate). The ONLY file you may
write/edit is `.autopilot/feedback.json` — and only by APPENDING objects to `.items`.
Do not rewrite, reorder, or delete existing items. Preserve valid JSON at all times.

1. Read `.autopilot/feedback.json` first. Claude's reviewer and adversary already ran
   this cycle. Note every `open` item — do NOT re-flag any issue whose `detail`
   substantively matches one already present. That's overlap; skip it.
2. Diff to review: `git diff {{BASE_SHA}}..{{HEAD_SHA}}`.
3. You are a SECOND MODEL. Prioritize blind spots a Claude-family reviewer would share:
   concurrency/race conditions, off-by-one and boundary cases, error-path handling,
   security, and incorrect assumptions — over restyling or taste.
4. For each NEW finding, append an object to `.items` with:
   - `id`: `c{{CYCLE}}-x-NNN` (3-digit monotonic; `-x-` namespace, distinct from
     reviewer `-r-` and adversary `-a-`)
   - `cycle`: {{CYCLE}} (integer)
   - `source`: `"codex"`
   - `severity`: `"critical"` | `"important"` | `"minor"`
   - `category`: one of correctness / tests / architecture / perf / security / style
   - `title`: short title
   - `detail`: what + where as `file:line — explanation`
   - `status`: `"open"`
   - `resolution_sha`: null, `resolution_note`: null

Exit when done. Be specific. No vibes-based feedback.
```

**Step 2: Verify placeholders render**

Run (sanity check that `render_prompt`'s `{{VAR}}` → `envsubst` substitution finds no stray tokens):

```bash
grep -o '{{[A-Z_]*}}' prompts/05bx-codex.md | sort -u
```

Expected: `{{BASE_SHA}}`, `{{CYCLE}}`, `{{HEAD_SHA}}`, `{{TICKET}}`, `{{WT}}` — all exported by `run_review_cycle` (CYCLE, BASE_SHA, HEAD_SHA) and `bin/autopilot` (TICKET, WT). No others.

**Step 3: Commit**

```bash
git add prompts/05bx-codex.md
git commit -m "feat(prompts): add Codex cross-review prompt"
```

---

## Task 7: Wire the codex phase into `run_review_cycle`

**Files:**
- Modify: `lib/review.sh:21-23` (the phase sequence inside `run_review_cycle`)

**Step 1: Implement the wiring**

Replace the phase calls in `run_review_cycle` (currently review.sh:21-23):

```bash
  run_phase 05a-reviewer  || return 1
  run_phase 05b-adversary || return 1

  if codex_available; then
    local fb="$WT/.autopilot/feedback.json"
    cp "$fb" "$fb.bak"
    if run_phase 05bx-codex cross; then
      feedback_restore_if_corrupt "$fb" "$fb.bak" || return 1
      rm -f "$fb.bak"
    else
      log_err "Codex phase failed; restoring feedback.json"
      mv "$fb.bak" "$fb"
      return 1
    fi
  else
    log_warn "codex not on PATH; skipping cross-review (set/clear AUTOPILOT_CODEX_CMD to control)"
  fi

  run_phase 05c-fixer     || return 1
```

> On any codex failure path the cycle marker is never set, so re-running re-enters at
> `05a-reviewer`. The reviewer/adversary prompts are idempotent (they skip overlapping
> `open` items), and `feedback.json` is restored, so no findings are lost or duplicated.

**Step 2: Verify the existing review cycle still parses/lints**

Run: `make lint`
Expected: shellcheck passes (no new warnings in `lib/review.sh`).

**Step 3: Full test suite**

Run: `make test`
Expected: All pass.

**Step 4: Manual smoke (no codex installed) — confirm graceful skip**

Run:

```bash
AUTOPILOT_CODEX_CMD="not-a-real-binary exec" bash -c '
  source lib/ui.sh; source lib/agent.sh
  codex_available && echo "AVAILABLE" || echo "SKIP (expected)"
'
```

Expected: `SKIP (expected)`.

**Step 5: Commit**

```bash
git add lib/review.sh
git commit -m "feat(review): run Codex cross-review between adversary and fixer"
```

---

## Task 8: Documentation

**Files:**
- Modify: `README.md` (config table, phase-order diagram, Modes/flow note)

**Step 1: Update the config table**

In `README.md`, add a row to the configuration table (after the `AUTOPILOT_AGENT_CMD` row, ~README.md:73):

```markdown
| `AUTOPILOT_CODEX_CMD` | `codex exec --full-auto` | Cross-review agent run each cycle between adversary and fixer. Skipped if binary absent; empty to disable. |
```

**Step 2: Update the phase-order diagram**

In `README.md` "Phase order" (~README.md:95-97), annotate the review step:

```
worktree → research → plan → [checkpoint] → implement → review×3 → [checkpoint] → merge|pr|preview|hold
```

Add a line below the diagram:

```markdown
Each `review` cycle runs reviewer → adversary → **codex cross-review** (if `codex` is on PATH) → fixer.
```

**Step 3: Update the "Potential improvements" → "Agent-agnostic mode" note**

In `README.md` (~README.md:179-184), note that the profile seam now exists:

```markdown
The agent-profile seam (`lib/agent.sh::agent_cmd_for` / `agent_filter_for`) already
dispatches command + output filter by profile name (`primary`, `cross`). Extending it to
a full `AUTOPILOT_AGENT=claude|codex|aider` selector for the *primary* agent is the
natural next step.
```

**Step 4: Commit**

```bash
git add README.md
git commit -m "docs(README): document Codex cross-review and AUTOPILOT_CODEX_CMD"
```

---

## Final verification

**Step 1: Full suite + lint**

Run: `make test && make lint`
Expected: All bats pass; shellcheck clean.

**Step 2: Confirm the new test files are wired**

Run: `bats tests/test_agent.bats tests/test_config.bats tests/test_review.bats`
Expected: PASS.

**Step 3: Review the full diff against the design**

Run: `git diff main...HEAD --stat`
Expected files changed: `lib/config.sh`, `lib/agent.sh`, `lib/review.sh`, `prompts/05bx-codex.md`, `.autopilotrc.example`, `README.md`, `tests/test_config.bats`, `tests/test_agent.bats`, `tests/test_review.bats`, plus the two `docs/plans/` files.

---

## Out of scope (YAGNI)

- Codex cost tracking (no `total_cost_usd` event; `state_add_cost` already skips it).
- A full `AUTOPILOT_AGENT=claude|codex|aider` primary-agent selector (the seam is laid, the selector is future work).
- Integration tests for the full reviewer→adversary→codex→fixer cycle (existing README-documented gap; unit coverage of the new helpers + guard is the scope here).
- Running codex only on cycle 1, or in parallel with the reviewer (rejected in brainstorm — every-cycle, after-adversary was chosen).
