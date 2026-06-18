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

# --- feedback_open_count: convergence signal for early-exit --------------------

@test "feedback_open_count is 0 for an empty feedback file" {
  echo '{"cycles":[],"items":[]}' > "$TMP/fb.json"
  run feedback_open_count "$TMP/fb.json"
  [ "$output" = "0" ]
}

@test "feedback_open_count counts only items with status open" {
  cat > "$TMP/fb.json" <<'JSON'
{"cycles":[],"items":[
  {"id":"a","status":"open"},
  {"id":"b","status":"fixed"},
  {"id":"c","status":"open"},
  {"id":"d","status":"dropped_by_adversary"},
  {"id":"e","status":"wontfix"}
]}
JSON
  run feedback_open_count "$TMP/fb.json"
  [ "$output" = "2" ]
}

@test "feedback_open_count is 0 when file is missing or malformed" {
  run feedback_open_count "$TMP/nope.json"
  [ "$output" = "0" ]
  printf '{ not json' > "$TMP/bad.json"
  run feedback_open_count "$TMP/bad.json"
  [ "$output" = "0" ]
}

# --- run_review_cycle early-exit ----------------------------------------------
# These drive run_review_cycle with stubbed phases over a minimal git repo, to
# prove the convergence decision (codex stays a finder; the fixer is gated on
# whether the finder pass left any open items).

_setup_review_wt() {
  WT="$TMP/wt"; mkdir -p "$WT/.autopilot"
  ( cd "$WT" && git init -q && git config user.email t@t.t && git config user.name t \
      && echo x > f.txt && git add . && git commit -q -m init \
      && git update-ref refs/remotes/origin/main HEAD )
  echo '{"cycles":[],"items":[]}' > "$WT/.autopilot/feedback.json"
  export WT
  CALLS="$TMP/calls"; : > "$CALLS"; export CALLS
  # Stubs (config.sh / agent.sh are not sourced here):
  default_branch() { echo main; }
  codex_available() { return 1; }   # codex disabled in these tests
}

@test "run_review_cycle converges and skips the fixer when no open findings" {
  _setup_review_wt
  # finders run but add nothing
  run_phase() { printf '%s\n' "$1" >> "$CALLS"; return 0; }
  run run_review_cycle 1
  [ "$status" -eq "$REVIEW_CONVERGED" ] \
    && grep -qx 05a-reviewer "$CALLS" \
    && grep -qx 05b-adversary "$CALLS" \
    && ! grep -qx 05c-fixer "$CALLS"
}

@test "run_review_cycle runs the fixer when the finder pass leaves open items" {
  _setup_review_wt
  # the reviewer finds one open item
  run_phase() {
    printf '%s\n' "$1" >> "$CALLS"
    if [ "$1" = "05a-reviewer" ]; then
      local t; t=$(mktemp)
      jq '.items += [{"id":"c1-r-001","cycle":1,"status":"open","severity":"important"}]' \
        "$WT/.autopilot/feedback.json" > "$t" && mv "$t" "$WT/.autopilot/feedback.json"
    fi
    return 0
  }
  run run_review_cycle 1
  [ "$status" -eq 0 ] && grep -qx 05c-fixer "$CALLS"
}
