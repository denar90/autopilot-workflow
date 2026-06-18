#!/usr/bin/env bash
# Phase ordering library. Source-only; defines functions.

_AUTOPILOT_PHASES=(
  none
  worktree_done
  research_done
  plan_done
  plan_approved
  implement_done
  review_cycle_1_done
  review_cycle_2_done
  review_cycle_3_done
  visual_verify_done
  review_approved
  merged
)

phase_index() {
  local target="$1"
  local i
  for i in "${!_AUTOPILOT_PHASES[@]}"; do
    if [[ "${_AUTOPILOT_PHASES[$i]}" == "$target" ]]; then
      echo "$i"
      return 0
    fi
  done
  echo "phase_index: unknown phase '$target'" >&2
  return 1
}

phase_lt() {
  local a b
  a=$(phase_index "$1") || return 2
  b=$(phase_index "$2") || return 2
  [[ "$a" -lt "$b" ]]
}
