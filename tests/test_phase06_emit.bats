#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/phase06.sh"
}

make_fake_wt() {
  local dir="$BATS_TEST_TMPDIR/wt"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q && git config user.email t@t.t && git config user.name t \
      && echo a > a.txt && git add . && git commit -q -m a )
  echo "$dir"
}

@test "emit_ready_file: writes ready file when AUTOPILOT_QUEUE_DIR is set" {
  wt=$(make_fake_wt)
  base=$(git -C "$wt" rev-parse HEAD)
  ( cd "$wt" && echo b > b.txt && git add . && git commit -q -m b )
  head=$(git -C "$wt" rev-parse HEAD)

  export AUTOPILOT_QUEUE_DIR="$BATS_TEST_TMPDIR/q"
  emit_ready_file TRA-1 feature/tra-1 pr "https://linear/TRA-1" "https://gh/pr/1" "$base" "$head" "$wt"
  [ -f "$AUTOPILOT_QUEUE_DIR/TRA-1.ready.json" ]
  jq -e '.ticket == "TRA-1" and .actionTaken == "pr"' "$AUTOPILOT_QUEUE_DIR/TRA-1.ready.json"
  jq -e '.changedPaths | index("b.txt")' "$AUTOPILOT_QUEUE_DIR/TRA-1.ready.json"
}

@test "emit_ready_file: skips when AUTOPILOT_QUEUE_DIR is unset" {
  unset AUTOPILOT_QUEUE_DIR || true
  emit_ready_file TRA-2 feature/tra-2 pr "" "" "a" "b" "/tmp/x"
  # Should be a no-op; no assertion required beyond non-failure.
}
