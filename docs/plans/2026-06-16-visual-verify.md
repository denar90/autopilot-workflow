# Visual Verification Phase — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a gated `visual-verify` phase that, for UI-related tasks, launches the app, drives the acceptance flows in a browser, captures screenshots, and judges the result against the ticket/plan acceptance criteria — feeding unmet criteria back into the existing `feedback.json` → fixer path.

**Design decisions (from brainstorm):**
- **Gating:** agent self-decides by default; explicit override `AUTOPILOT_VISUAL=auto|on|off` (`auto` = run the phase but let the agent skip non-UI work; `on` = always verify; `off` = never run the phase).
- **App launch:** reuse the project's own run-skill/script. `AUTOPILOT_APP_CMD` (optional) names the launch command; when empty the agent uses the project's run skill or dev script.
- **Findings:** unmet criteria become `status:"open"` items (`source:"visual"`) so the fixer addresses them; plus a human-readable `.autopilot/visual-report.md` with screenshot references.
- **Placement:** after the code-review loop converges, before the `review_approved` checkpoint — so the human sees both the code-review summary and the visual report when deciding merge.

**Tech stack:** Bash 3.2, jq, bats. Browser automation via the worktree agent's Playwright skill (`webapp-testing` / `dev-browser`) or a project Playwright MCP. Claude reads the screenshots to self-judge.

---

## Constraints / what already exists
- `feedback.json` items use `status` ∈ open/fixed/dropped_by_adversary/wontfix; `feedback_open_count` (lib/review.sh) is the convergence signal; the fixer (`05c-fixer`) fixes `open` items.
- Acceptance criteria source: `.autopilot/ticket.json` `.description` (Linear) in ticket mode; the plan at `state.plan_path` in plan-file mode.
- Phase ladder is `lib/phases.sh::_AUTOPILOT_PHASES`; markers gate via `need`/`mark_phase`.
- Review phases run on `AUTOPILOT_MODEL_REVIEW` via the `review` agent profile.

---

## Task 1: Config — `AUTOPILOT_VISUAL` and `AUTOPILOT_APP_CMD`
- `lib/config.sh`: add `: "${AUTOPILOT_VISUAL:=auto}"` and `: "${AUTOPILOT_APP_CMD:=}"`; add both to the export list.
- `visual_enabled()` helper (config.sh): returns true unless `AUTOPILOT_VISUAL=off`.
- Tests (`tests/test_config.bats`): default `auto`; caller override preserved; `visual_enabled` false only for `off`.
- `.autopilotrc.example`: document both.

## Task 2: Phase-ladder slot `visual_verify_done`
- `lib/phases.sh`: insert `visual_verify_done` between `review_cycle_3_done` and `review_approved`.
- Tests (`tests/test_phases.bats`): ordering — `review_cycle_3_done` < `visual_verify_done` < `review_approved`.

## Task 3: Visual-verify prompt
- Create `prompts/07-visual-verify.md`:
  - Verify cwd. Read acceptance criteria from `.autopilot/ticket.json` (`.description`) or the plan.
  - **Gate:** if `{{VISUAL_MODE}}` is `auto` and the diff `{{BASE_SHA}}..{{HEAD_SHA}}` has no user-facing UI change (no frontend files; criteria not visual), write a one-line "skipped — no UI" note to `.autopilot/visual-report.md` and exit without adding items. If `on`, always proceed.
  - Launch the app: use `{{APP_CMD}}` if set, else the project's run skill / dev script; wait for readiness; ensure teardown.
  - Drive the acceptance flows with the Playwright skill; save screenshots to `.autopilot/screenshots/`.
  - For each unmet criterion append an `open` item (`source:"visual"`, `id:"cV-v-NNN"`, `detail` = criterion + screenshot path).
  - Write `.autopilot/visual-report.md` (each criterion: met/unmet + screenshot ref).
- Verify placeholders render: `{{TICKET}} {{WT}} {{BASE_SHA}} {{HEAD_SHA}} {{VISUAL_MODE}} {{APP_CMD}}`.

## Task 4: Wire the gated visual loop into `bin/autopilot`
- After the review-cycle loop, before `if need review_approved`:
  ```bash
  if need visual_verify_done; then
    if visual_enabled; then
      export VISUAL_MODE="$AUTOPILOT_VISUAL" APP_CMD="$AUTOPILOT_APP_CMD"
      BASE_SHA=$(git -C "$WT" merge-base "$(base_ref "$WT")" HEAD)
      HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
      export BASE_SHA HEAD_SHA
      for v in 1 2; do                       # bounded verify→fix→re-verify
        run_phase 07-visual-verify review || { log_err "visual-verify failed"; exit 1; }
        [[ "$(feedback_open_count "$WT/.autopilot/feedback.json")" -eq 0 ]] && break
        run_phase 05c-fixer review || { log_err "visual fix failed"; exit 1; }
      done
    else
      log_info "Visual verification disabled (AUTOPILOT_VISUAL=off)."
    fi
    mark_phase visual_verify_done
  fi
  ```
- Smoke: stub `run_phase`, assert the loop gates on `visual_enabled` and breaks when no open items.

## Task 5: Surface the report at the review checkpoint
- `lib/checkpoint.sh::checkpoint_review`: if `.autopilot/visual-report.md` exists, print its path (and a one-line tally) alongside the feedback summary.

## Task 6: Docs
- `README.md`: config-table rows for `AUTOPILOT_VISUAL` / `AUTOPILOT_APP_CMD`; phase-order note (review → **visual-verify (UI tasks)** → checkpoint → merge); a "Visual verification" subsection covering the gate, the run-skill dependency, and that screenshots land in `.autopilot/screenshots/`.

---

## Out of scope (YAGNI)
- Pixel-diff/visual-regression baselines (this is criteria-based judgment, not snapshot diffing).
- Auto-installing a browser/Playwright — relies on the project's existing run-skill/e2e tooling.
- More than 2 visual verify→fix rounds.

## Validation note
The deterministic scaffolding (config, gating, phase ladder, loop wiring) is unit-testable. The actual browser run, app launch, and screenshot judgment can only be validated on a **real UI task** (e.g. the kids-routine app) — that's the acceptance test for this feature.
