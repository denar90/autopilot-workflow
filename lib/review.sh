#!/usr/bin/env bash
# Review cycle driver. Requires $WT and prior libs sourced.

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

  run_phase 05a-reviewer  || return 1
  run_phase 05b-adversary || return 1
  run_phase 05c-fixer     || return 1
}
