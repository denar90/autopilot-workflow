#!/usr/bin/env bash
# Review cycle driver. Requires $WT and prior libs sourced.

# Sentinel return code from run_review_cycle: the finder pass (reviewer + adversary
# + codex) left no open findings, so the cycle converged and the driver should stop
# the loop instead of running more cycles. Distinct from 0 (ran fixer, continue) and
# 1 (a phase failed).
REVIEW_CONVERGED=10

# feedback_open_count <feedback.json> — number of items still needing a fix (status
# == "open"). The convergence signal for early-exit. 0 on a missing/malformed file.
feedback_open_count() {
  jq '[.items[] | select(.status == "open")] | length' "$1" 2>/dev/null || echo 0
}

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

# run_review_cycle <N>
run_review_cycle() {
  local n="$1"
  local base head
  base=$(git -C "$WT" merge-base "$(base_ref "$WT")" HEAD)
  head=$(git -C "$WT" rev-parse HEAD)

  local tmp
  tmp=$(mktemp)
  jq --argjson n "$n" --arg b "$base" --arg h "$head" --arg t "$(date -u +%FT%TZ)" \
    '.cycles += [{n: $n, started_at: $t, base_sha: $b, head_sha: $h}]' \
    "$WT/.autopilot/feedback.json" > "$tmp"
  mv "$tmp" "$WT/.autopilot/feedback.json"

  export CYCLE="$n" BASE_SHA="$base" HEAD_SHA="$head"

  # Finder pass: reviewer + adversary + (second-model) codex. All three append
  # open findings to feedback.json before the convergence check below.
  run_phase 05a-reviewer  review || return 1
  run_phase 05b-adversary review || return 1

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

  # Early-exit: if the finder pass (including codex) left nothing open, there is
  # nothing for the fixer to do and re-reviewing an unchanged, clean diff would
  # only burn tokens. Signal convergence so the driver stops the cycle loop.
  if [[ "$(feedback_open_count "$WT/.autopilot/feedback.json")" -eq 0 ]]; then
    log_ok "Cycle ${n}: no open findings after review — converged, skipping fixer."
    return "$REVIEW_CONVERGED"
  fi

  run_phase 05c-fixer     review || return 1
  return 0
}
