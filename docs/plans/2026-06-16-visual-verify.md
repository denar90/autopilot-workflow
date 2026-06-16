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
- **Reference images:** `linear_fetch_via_api` currently fetches text only (`identifier/title/description/url/state/team`). Design mockups/screenshots in a Linear ticket (description-embedded `uploads.linear.app` images, or `attachments`) are NOT captured — so visual-verify has no baseline to compare against. Task 1b closes this.
- Phase ladder is `lib/phases.sh::_AUTOPILOT_PHASES`; markers gate via `need`/`mark_phase`.
- Review phases run on `AUTOPILOT_MODEL_REVIEW` via the `review` agent profile.

---

## Task 1: Config — `AUTOPILOT_VISUAL` and `AUTOPILOT_APP_CMD`
- `lib/config.sh`: add `: "${AUTOPILOT_VISUAL:=auto}"` and `: "${AUTOPILOT_APP_CMD:=}"`; add both to the export list.
- `visual_enabled()` helper (config.sh): returns true unless `AUTOPILOT_VISUAL=off`.
- Tests (`tests/test_config.bats`): default `auto`; caller override preserved; `visual_enabled` false only for `off`.
- `.autopilotrc.example`: document both.

## Task 1b: Capture Linear acceptance images as comparison baselines
- `lib/linear.sh`:
  - Extend the GraphQL query in `linear_fetch_via_api` to include `attachments { nodes { url title } }`; keep `description`.
  - `linear_extract_image_urls <ticket.json>` — pure helper: emit image URLs from the description markdown (`!\[...\]\(<url>\)`, `https://uploads.linear.app/...`) plus image-like attachment URLs. Unit-testable.
  - `linear_fetch_criteria_images <ticket.json> <out-dir>` — download each URL with `curl -H "Authorization: $LINEAR_API_KEY" -L` into `<out-dir>`; write the local paths back into `ticket.json` as `.criteria_images`. Best-effort: a failed download is logged and skipped, never fatal. Figma/non-image links are recorded under `.criteria_links` for the agent to note, not downloaded.
- `lib/phase01.sh`: after `linear_fetch`, call `linear_fetch_criteria_images "$WT/.autopilot/ticket.json" "$WT/.autopilot/criteria"`.
- MCP fallback: the `01-worktree-fetch` prompt also instructs the agent to save any ticket images to `.autopilot/criteria/` (via the Linear MCP `extract_images`).
- Tests (`tests/test_linear.bats`): `linear_extract_image_urls` pulls markdown + uploads URLs and ignores non-image links; tolerates a description with no images (empty output).

## Task 2: Phase-ladder slot `visual_verify_done`
- `lib/phases.sh`: insert `visual_verify_done` between `review_cycle_3_done` and `review_approved`.
- Tests (`tests/test_phases.bats`): ordering — `review_cycle_3_done` < `visual_verify_done` < `review_approved`.

## Task 3: Visual-verify prompt
- Create `prompts/07-visual-verify.md`:
  - Verify cwd. Read acceptance criteria from `.autopilot/ticket.json` (`.description`) or the plan.
  - **Load reference designs:** read any images listed in `.autopilot/ticket.json` `.criteria_images` (files under `.autopilot/criteria/`) as the comparison baseline, and note any `.criteria_links` (e.g. Figma) that couldn't be rendered. If there are none, verify against the textual criteria alone.
  - **Gate:** if `{{VISUAL_MODE}}` is `auto` and the diff `{{BASE_SHA}}..{{HEAD_SHA}}` has no user-facing UI change (no frontend files; criteria not visual), write a one-line "skipped — no UI" note to `.autopilot/visual-report.md` and exit without adding items. If `on`, always proceed.
  - Launch the app: use `{{APP_CMD}}` if set, else the project's run skill / dev script; wait for readiness; ensure teardown.
  - Drive the acceptance flows with the Playwright skill; save screenshots to `.autopilot/screenshots/`.
  - For each unmet criterion append an `open` item (`source:"visual"`, `id:"cV-v-NNN"`, `detail` = criterion + screenshot path + reference-image path when one exists).
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
