#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/phases.sh"
  source "$LIB_DIR/state.sh"
  TMP="$(mktemp -d)"
  export WT="$TMP"
  mkdir -p "$WT/.autopilot"
  cp "$LIB_DIR/../templates/state.json" "$WT/.autopilot/state.json"
}

teardown() {
  rm -rf "$TMP"
}

@test "state_phase returns 'none' from fresh template" {
  run state_phase
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "mark_phase updates state.json" {
  mark_phase worktree_done
  run state_phase
  [ "$output" = "worktree_done" ]
}

@test "mark_phase updates updated_at" {
  mark_phase worktree_done
  ts=$(jq -r .updated_at "$WT/.autopilot/state.json")
  [ "$ts" != "null" ]
  [ -n "$ts" ]
}

@test "mark_phase rejects unknown phase" {
  run mark_phase gibberish
  [ "$status" -ne 0 ]
}

@test "need returns success when current phase is behind target" {
  run need worktree_done
  [ "$status" -eq 0 ]
}

@test "need returns failure when current phase has reached target" {
  mark_phase worktree_done
  run need worktree_done
  [ "$status" -ne 0 ]
}

@test "state_set updates a top-level field" {
  state_set ticket "TRA-550"
  val=$(jq -r .ticket "$WT/.autopilot/state.json")
  [ "$val" = "TRA-550" ]
}

@test "state_total_cost starts at 0" {
  run state_total_cost
  [ "$output" = "0" ]
}

@test "state_add_cost accumulates total_cost_usd from result events" {
  local logf="$WT/phase.log"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' > "$logf"
  printf '%s\n' '{"type":"result","total_cost_usd":0.5,"duration_ms":100}' >> "$logf"
  state_add_cost "$logf"
  run state_total_cost
  [ "$output" = "0.5" ]
}

@test "state_add_cost is additive across multiple phases" {
  local a="$WT/a.log" b="$WT/b.log"
  printf '%s\n' '{"type":"result","total_cost_usd":0.25}' > "$a"
  printf '%s\n' '{"type":"result","total_cost_usd":1.5}' > "$b"
  state_add_cost "$a"
  state_add_cost "$b"
  run state_total_cost
  [ "$output" = "1.75" ]
}

@test "state_add_cost is a no-op when log has no result event" {
  local logf="$WT/noresult.log"
  printf '%s\n' '{"type":"assistant","message":{"content":[]}}' > "$logf"
  state_add_cost "$logf"
  run state_total_cost
  [ "$output" = "0" ]
}

@test "state_add_cost is a no-op when log file does not exist" {
  state_add_cost "$WT/does-not-exist.log"
  run state_total_cost
  [ "$output" = "0" ]
}

@test "state_add_cost picks the last result event when there are multiple" {
  local logf="$WT/multi.log"
  printf '%s\n' '{"type":"result","total_cost_usd":0.1}' > "$logf"
  printf '%s\n' '{"type":"result","total_cost_usd":0.9}' >> "$logf"
  state_add_cost "$logf"
  run state_total_cost
  [ "$output" = "0.9" ]
}

@test "state_write_last_wt creates the marker file" {
  export XDG_STATE_HOME="$TMP/xdg-state"
  state_write_last_wt "/some/worktree/path"
  marker="$XDG_STATE_HOME/autopilot/last-wt"
  [ -f "$marker" ]
  [ "$(cat "$marker")" = "/some/worktree/path" ]
}

@test "state_write_last_wt creates parent directory if missing" {
  export XDG_STATE_HOME="$TMP/deeply/nested/missing"
  [ ! -d "$XDG_STATE_HOME" ]
  state_write_last_wt "/wt"
  [ -d "$XDG_STATE_HOME/autopilot" ]
  [ -f "$XDG_STATE_HOME/autopilot/last-wt" ]
}

@test "state_write_last_wt overwrites previous value" {
  export XDG_STATE_HOME="$TMP/xdg-state"
  state_write_last_wt "/first"
  state_write_last_wt "/second"
  marker="$XDG_STATE_HOME/autopilot/last-wt"
  [ "$(cat "$marker")" = "/second" ]
}

@test "state_read_last_wt returns the most recent write" {
  export XDG_STATE_HOME="$TMP/xdg-state"
  state_write_last_wt "/wt/tra-123"
  run state_read_last_wt
  [ "$status" -eq 0 ]
  [ "$output" = "/wt/tra-123" ]
}

@test "state_read_last_wt returns empty when no marker exists" {
  export XDG_STATE_HOME="$TMP/never-written"
  run state_read_last_wt
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "state_write_last_wt round-trips through state_read_last_wt" {
  export XDG_STATE_HOME="$TMP/xdg-state"
  state_write_last_wt "/some/path with spaces/wt"
  run state_read_last_wt
  [ "$output" = "/some/path with spaces/wt" ]
}

@test "state_write_last_wt defaults to ~/.local/state when XDG_STATE_HOME unset" {
  unset XDG_STATE_HOME
  HOME="$TMP/fakehome"
  mkdir -p "$HOME"
  state_write_last_wt "/wt"
  [ -f "$HOME/.local/state/autopilot/last-wt" ]
  [ "$(cat "$HOME/.local/state/autopilot/last-wt")" = "/wt" ]
}
