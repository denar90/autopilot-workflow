#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/ui.sh"
  source "$LIB_DIR/metrics.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

_fixture_wt() {
  local wt="$TMP/wt"; mkdir -p "$wt/.autopilot/logs"
  cat > "$wt/.autopilot/state.json" <<'JSON'
{"ticket":"TRA-1","worktree":"/x","branch":"feature/tra-1","plan_path":".autopilot/plan.md","phase":"merged","updated_at":"2026-06-24T00:00:00Z","total_cost_usd":4.2}
JSON
  cat > "$wt/.autopilot/feedback.json" <<'JSON'
{"cycles":[{"n":1}],"items":[
  {"id":"c1-r-001","source":"reviewer","status":"fixed"},
  {"id":"c1-r-002","source":"reviewer","status":"dropped_by_adversary"},
  {"id":"c1-a-001","source":"adversary","status":"fixed"},
  {"id":"cV-v-001","source":"codex","status":"open"}
]}
JSON
  printf '%s\n' '{"type":"result","total_cost_usd":2.0,"num_turns":10,"duration_ms":1000}' > "$wt/.autopilot/logs/04-implement.log"
  printf '%s\n' '{"type":"result","total_cost_usd":0.5,"num_turns":3,"duration_ms":500}' > "$wt/.autopilot/logs/05a-reviewer.log"
  echo "$wt"
}

@test "metrics_enabled defaults on; off disables" {
  ( unset AUTOPILOT_METRICS; metrics_enabled ) \
    && AUTOPILOT_METRICS=on metrics_enabled \
    && ! AUTOPILOT_METRICS=off metrics_enabled
}

@test "metrics_build_record emits cost, cycles, phase, ticket, findings_by_source" {
  wt=$(_fixture_wt)
  export TICKET=TRA-1 PROJECT=trayoai AUTOPILOT_MODE=full
  run metrics_build_record "$wt"
  [ "$status" -eq 0 ] \
    && echo "$output" | jq -e '.cost_usd == 4.2' >/dev/null \
    && echo "$output" | jq -e '.cycles == 1' >/dev/null \
    && echo "$output" | jq -e '.phase == "merged"' >/dev/null \
    && echo "$output" | jq -e '.ticket == "TRA-1"' >/dev/null \
    && echo "$output" | jq -e '.project == "trayoai"' >/dev/null \
    && echo "$output" | jq -e '.findings_total == 4' >/dev/null \
    && echo "$output" | jq -e '.findings_by_source.reviewer.fixed == 1' >/dev/null \
    && echo "$output" | jq -e '.findings_by_source.reviewer.dropped_by_adversary == 1' >/dev/null \
    && echo "$output" | jq -e '.findings_by_source.adversary.fixed == 1' >/dev/null \
    && echo "$output" | jq -e '.findings_by_source.codex.open == 1' >/dev/null
}

@test "metrics_build_record includes per-phase cost/turns from logs" {
  wt=$(_fixture_wt)
  run metrics_build_record "$wt"
  [ "$status" -eq 0 ] \
    && echo "$output" | jq -e '.per_phase["04-implement"].cost == 2.0' >/dev/null \
    && echo "$output" | jq -e '.per_phase["04-implement"].turns == 10' >/dev/null \
    && echo "$output" | jq -e '.per_phase["05a-reviewer"].cost == 0.5' >/dev/null
}

@test "metrics_build_record degrades when feedback.json is absent" {
  wt="$TMP/wt2"; mkdir -p "$wt/.autopilot"
  echo '{"ticket":"TRA-9","phase":"implement_done","total_cost_usd":1.0}' > "$wt/.autopilot/state.json"
  run metrics_build_record "$wt"
  [ "$status" -eq 0 ] \
    && echo "$output" | jq -e '.findings_total == 0' >/dev/null \
    && echo "$output" | jq -e '.cycles == 0' >/dev/null \
    && echo "$output" | jq -e '.per_phase == {}' >/dev/null
}

@test "metrics_build_record fails when state.json is missing" {
  run metrics_build_record "$TMP/nonexistent"
  [ "$status" -ne 0 ]
}

@test "metrics_build_record emits a single compact JSONL line" {
  wt=$(_fixture_wt)
  run metrics_build_record "$wt"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
}
