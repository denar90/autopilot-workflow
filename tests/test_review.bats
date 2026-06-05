#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/ui.sh"
  source "$LIB_DIR/review.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

@test "feedback_restore_if_corrupt leaves valid JSON untouched, returns 0" {
  echo '{"items":[{"id":"c1-r-001"}]}' > "$TMP/fb.json"
  cp "$TMP/fb.json" "$TMP/fb.json.bak"
  run feedback_restore_if_corrupt "$TMP/fb.json" "$TMP/fb.json.bak"
  [ "$status" -eq 0 ]
  run jq -r '.items[0].id' "$TMP/fb.json"
  [ "$output" = "c1-r-001" ]
}

@test "feedback_restore_if_corrupt restores backup on invalid JSON, returns 1" {
  echo '{"items":[{"id":"good"}]}' > "$TMP/fb.json.bak"
  printf '{ this is not valid json' > "$TMP/fb.json"
  run feedback_restore_if_corrupt "$TMP/fb.json" "$TMP/fb.json.bak"
  [ "$status" -eq 1 ]
  run jq -r '.items[0].id' "$TMP/fb.json"
  [ "$output" = "good" ]
}
