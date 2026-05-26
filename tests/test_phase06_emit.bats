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

@test "gh_available: fails when gh is not installed" {
  # Force PATH to a dir with no `gh` binary.
  PATH="$BATS_TEST_TMPDIR" run gh_available
  [ "$status" -ne 0 ]
}

@test "gh_available: fails when gh exists but auth status is non-zero" {
  # Shim gh with a stub that exits non-zero on `gh auth status`.
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 1; fi
exit 0
EOF
  chmod +x "$bin/gh"
  PATH="$bin:$PATH" run gh_available
  [ "$status" -ne 0 ]
}

@test "gh_available: succeeds when gh exists and auth status is OK" {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin/gh"
  PATH="$bin:$PATH" run gh_available
  [ "$status" -eq 0 ]
}

@test "emit_ready_file: action push_only is recorded when set" {
  wt=$(make_fake_wt)
  base=$(git -C "$wt" rev-parse HEAD)
  ( cd "$wt" && echo c > c.txt && git add . && git commit -q -m c )
  head=$(git -C "$wt" rev-parse HEAD)

  export AUTOPILOT_QUEUE_DIR="$BATS_TEST_TMPDIR/q"
  emit_ready_file TRA-3 feature/tra-3 push_only "https://linear/TRA-3" "" "$base" "$head" "$wt"
  jq -e '.actionTaken == "push_only" and .prUrl == ""' "$AUTOPILOT_QUEUE_DIR/TRA-3.ready.json"
}
