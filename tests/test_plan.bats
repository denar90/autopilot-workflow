#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/ui.sh"
  source "$LIB_DIR/phases.sh"
  source "$LIB_DIR/state.sh"
  source "$LIB_DIR/plan.sh"
  AUTOPILOT_ROOT="$(cd "$LIB_DIR/.." && pwd)"
  export AUTOPILOT_ROOT
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

@test "plan_slug strips leading ISO date and .md extension" {
  run plan_slug "docs/plans/2026-06-04-shared-app-sidebar.md"
  [ "$status" -eq 0 ]
  [ "$output" = "shared-app-sidebar" ]
}

@test "plan_slug handles a bare filename without date prefix" {
  run plan_slug "my-cool-plan.md"
  [ "$output" = "my-cool-plan" ]
}

@test "plan_slug strips only a full YYYY-MM-DD- prefix, not arbitrary numbers" {
  run plan_slug "123-not-a-date.md"
  [ "$output" = "123-not-a-date" ]
}

@test "plan_branch_name composes feature/<slug>" {
  run plan_branch_name "shared-app-sidebar"
  [ "$output" = "feature/shared-app-sidebar" ]
}

@test "is_plan_input true for a .md path (even if it does not exist)" {
  run is_plan_input "docs/plans/whatever.md"
  [ "$status" -eq 0 ]
}

@test "is_plan_input true for an existing file without .md extension" {
  printf 'x' > "$TMP/somefile"
  run is_plan_input "$TMP/somefile"
  [ "$status" -eq 0 ]
}

@test "is_plan_input false for a Linear identifier" {
  run is_plan_input "TRA-550"
  [ "$status" -ne 0 ]
}

@test "is_plan_input false for a Linear URL" {
  run is_plan_input "https://linear.app/trayo/issue/TRA-550/add-foo-bar"
  [ "$status" -ne 0 ]
}

@test "plan_seed_worktree installs templates, plan, stubs, and state fields" {
  printf '# Plan\n\n## Task 1\nDo the thing.\n' > "$TMP/2026-06-04-shared-app-sidebar.md"
  wt="$TMP/wt"; mkdir -p "$wt"

  plan_seed_worktree "$wt" "$TMP/2026-06-04-shared-app-sidebar.md" "shared-app-sidebar"

  # templates installed
  [ -f "$wt/.autopilot/state.json" ]
  [ -f "$wt/.autopilot/feedback.json" ]
  # plan copied verbatim to .autopilot/plan.md (out of the tracked tree)
  [ -f "$wt/.autopilot/plan.md" ]
  grep -q "## Task 1" "$wt/.autopilot/plan.md"
  # research stub stands in for the skipped research phase
  grep -q "Plan-file mode" "$wt/.autopilot/research.md"
  # ticket.json stub keeps phase06 / review / codex prompts working
  run jq -r '.identifier' "$wt/.autopilot/ticket.json"
  [ "$output" = "shared-app-sidebar" ]
  run jq -r '.title' "$wt/.autopilot/ticket.json"
  [ "$output" = "shared-app-sidebar" ]
  # state fields point the implement phase at the supplied plan
  run jq -r '.plan_path' "$wt/.autopilot/state.json"
  [ "$output" = ".autopilot/plan.md" ]
  run jq -r '.branch' "$wt/.autopilot/state.json"
  [ "$output" = "feature/shared-app-sidebar" ]
  run jq -r '.ticket' "$wt/.autopilot/state.json"
  [ "$output" = "shared-app-sidebar" ]
}
