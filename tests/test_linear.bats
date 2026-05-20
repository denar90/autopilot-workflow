#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/linear.sh"
}

@test "linear_parse_ticket from canonical URL" {
  run linear_parse_ticket "https://linear.app/trayo/issue/TRA-550/add-foo-bar"
  [ "$status" -eq 0 ]
  [ "$output" = "TRA-550" ]
}

@test "linear_parse_ticket from URL with no slug" {
  run linear_parse_ticket "https://linear.app/trayo/issue/TRA-12"
  [ "$status" -eq 0 ]
  [ "$output" = "TRA-12" ]
}

@test "linear_parse_ticket from bare identifier" {
  run linear_parse_ticket "TRA-550"
  [ "$status" -eq 0 ]
  [ "$output" = "TRA-550" ]
}

@test "linear_parse_ticket uppercases prefix" {
  run linear_parse_ticket "https://linear.app/foo/issue/abc-1/hi"
  [ "$status" -eq 0 ]
  [ "$output" = "ABC-1" ]
}

@test "linear_parse_ticket rejects empty input" {
  run linear_parse_ticket ""
  [ "$status" -ne 0 ]
}

@test "linear_parse_ticket rejects nonsense" {
  run linear_parse_ticket "https://example.com/foo"
  [ "$status" -ne 0 ]
}

@test "linear_parse_slug from URL with slug" {
  run linear_parse_slug "https://linear.app/trayo/issue/TRA-550/add-foo-bar"
  [ "$status" -eq 0 ]
  [ "$output" = "add-foo-bar" ]
}

@test "linear_parse_slug returns empty for URL without slug" {
  run linear_parse_slug "https://linear.app/trayo/issue/TRA-550"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "linear_branch_name composes ticket + slug" {
  run linear_branch_name "TRA-550" "add-foo-bar"
  [ "$output" = "feature/tra-550-add-foo-bar" ]
}

@test "linear_branch_name omits slug when empty" {
  run linear_branch_name "TRA-550" ""
  [ "$output" = "feature/tra-550" ]
}
