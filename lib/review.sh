#!/usr/bin/env bash
# Review cycle driver. Requires $WT and prior libs sourced.

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
  local base head main_branch
  main_branch=$(default_branch "$WT")
  base=$(git -C "$WT" merge-base "origin/$main_branch" HEAD)
  head=$(git -C "$WT" rev-parse HEAD)

  local tmp
  tmp=$(mktemp)
  jq --argjson n "$n" --arg b "$base" --arg h "$head" --arg t "$(date -u +%FT%TZ)" \
    '.cycles += [{n: $n, started_at: $t, base_sha: $b, head_sha: $h}]' \
    "$WT/.autopilot/feedback.json" > "$tmp"
  mv "$tmp" "$WT/.autopilot/feedback.json"

  export CYCLE="$n" BASE_SHA="$base" HEAD_SHA="$head"

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

  run_phase 05c-fixer     review || return 1
}
