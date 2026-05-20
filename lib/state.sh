#!/usr/bin/env bash
# State management. Requires $WT and phases.sh to be sourced.

_state_file() { echo "$WT/.autopilot/state.json"; }

state_phase() {
  jq -r .phase "$(_state_file)" 2>/dev/null || echo "none"
}

state_set() {
  local key="$1" value="$2"
  local tmp
  tmp=$(mktemp)
  jq --arg v "$value" ".${key} = \$v" "$(_state_file)" > "$tmp"
  mv "$tmp" "$(_state_file)"
}

mark_phase() {
  local phase="$1"
  phase_index "$phase" >/dev/null || return 1
  local tmp now
  tmp=$(mktemp)
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq --arg p "$phase" --arg t "$now" '.phase = $p | .updated_at = $t' \
    "$(_state_file)" > "$tmp"
  mv "$tmp" "$(_state_file)"
}

need() {
  phase_lt "$(state_phase)" "$1"
}
