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

# state_add_cost <logfile> — extract total_cost_usd from the final result event
# in <logfile> and add it to state.total_cost_usd. No-op when log lacks a result.
state_add_cost() {
  local logf="$1"
  [[ -f "$logf" ]] || return 0
  local cost
  cost=$(grep '"type":"result"' "$logf" | tail -n1 \
          | jq -r '.total_cost_usd // empty' 2>/dev/null) || return 0
  [[ -z "$cost" ]] && return 0
  local tmp
  tmp=$(mktemp)
  jq --argjson c "$cost" '.total_cost_usd = ((.total_cost_usd // 0) + $c)' \
    "$(_state_file)" > "$tmp"
  mv "$tmp" "$(_state_file)"
}

state_total_cost() {
  jq -r '.total_cost_usd // 0' "$(_state_file)" 2>/dev/null || echo "0"
}

# Global marker: last worktree autopilot was driving. Read by the optional
# shell wrapper (see README "Auto-cd") to cd the parent shell into the worktree.
_last_wt_marker() {
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/autopilot/last-wt"
}

state_write_last_wt() {
  local wt="$1" marker
  marker=$(_last_wt_marker)
  mkdir -p "$(dirname "$marker")"
  printf '%s\n' "$wt" > "$marker"
}

state_read_last_wt() {
  local marker
  marker=$(_last_wt_marker)
  [[ -f "$marker" ]] && cat "$marker"
  return 0
}
