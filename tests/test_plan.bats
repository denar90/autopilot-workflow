#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/ui.sh"
  source "$LIB_DIR/plan.sh"
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
