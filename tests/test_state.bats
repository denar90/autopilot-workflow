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
