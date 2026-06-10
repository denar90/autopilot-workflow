#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/ui.sh"
  source "$LIB_DIR/agent.sh"
}

@test "agent_cmd_for primary returns AUTOPILOT_AGENT_CMD" {
  export AUTOPILOT_AGENT_CMD="claude -p"
  export AUTOPILOT_CODEX_CMD="codex exec"
  [ "$(agent_cmd_for primary)" = "claude -p" ]
}

@test "agent_cmd_for cross returns AUTOPILOT_CODEX_CMD" {
  export AUTOPILOT_AGENT_CMD="claude -p"
  export AUTOPILOT_CODEX_CMD="codex exec"
  [ "$(agent_cmd_for cross)" = "codex exec" ]
}

@test "agent_cmd_for unknown profile falls back to primary" {
  export AUTOPILOT_AGENT_CMD="claude -p"
  [ "$(agent_cmd_for whatever)" = "claude -p" ]
}

@test "agent_filter_for primary returns agent_pretty" {
  [ "$(agent_filter_for primary)" = "agent_pretty" ]
}

@test "agent_filter_for cross returns codex_pretty" {
  [ "$(agent_filter_for cross)" = "codex_pretty" ]
}

@test "codex_available false when AUTOPILOT_CODEX_CMD empty" {
  export AUTOPILOT_CODEX_CMD=""
  run codex_available
  [ "$status" -ne 0 ]
}

@test "codex_available false when binary not on PATH" {
  export AUTOPILOT_CODEX_CMD="definitely-not-a-real-binary-xyz exec"
  run codex_available
  [ "$status" -ne 0 ]
}

@test "codex_available true when first word resolves on PATH" {
  # 'env' is a coreutils binary present on every PATH
  export AUTOPILOT_CODEX_CMD="env exec --full-auto"
  run codex_available
  [ "$status" -eq 0 ]
}

@test "run_phase dispatches filter by profile" {
  TMP="$(mktemp -d)"
  export AUTOPILOT_ROOT="$TMP/root"
  export WT="$TMP/wt"
  mkdir -p "$AUTOPILOT_ROOT/prompts" "$WT/.autopilot"
  # A codex agent_message event: agent_pretty (primary) drops it; codex_pretty
  # (cross) renders the text. This proves the filter is dispatched by profile.
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"HELLO"}}' \
    > "$AUTOPILOT_ROOT/prompts/smoke.md"
  export AUTOPILOT_AGENT_CMD="cat"
  export AUTOPILOT_CODEX_CMD="cat"

  out_primary="$(run_phase smoke primary | sed $'s/\x1b\\[[0-9;]*m//g')"
  out_cross="$(run_phase smoke cross | sed $'s/\x1b\\[[0-9;]*m//g')"
  rm -rf "$TMP"

  # Cleanup happens before the assertions so a failing assertion (not the rm)
  # is the test's final command — bats only fails a test on its last command.
  # agent_pretty does not understand codex events → drops the line
  [[ "$out_primary" != *"HELLO"* ]]
  # codex_pretty renders the agent_message text
  [[ "$out_cross" == *"HELLO"* ]]
}

@test "agent_pretty extracts assistant text" {
  json='{"type":"assistant","message":{"content":[{"type":"text","text":"hello world"}]}}'
  out=$(printf '%s\n' "$json" | agent_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"hello world"* ]]
}

@test "agent_pretty formats tool_use as arrow + name + args" {
  json='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.ts"}}]}}'
  out=$(printf '%s\n' "$json" | agent_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"→ Read"* ]]
  [[ "$out" == *"file_path=/a/b.ts"* ]]
}

@test "agent_pretty does not truncate long string args" {
  long=$(printf 'x%.0s' {1..120})
  json="{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"$long\"}}]}}"
  out=$(printf '%s\n' "$json" | agent_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"$long"* ]]
}

@test "agent_pretty collapses object/array args" {
  json='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a","obj":{"nested":1},"arr":[1,2,3]}}]}}'
  out=$(printf '%s\n' "$json" | agent_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"obj={…}"* ]]
  [[ "$out" == *"arr=[…]"* ]]
}

@test "agent_pretty prints task_progress description" {
  json='{"type":"system","subtype":"task_progress","description":"Reading foo.ts"}'
  out=$(printf '%s\n' "$json" | agent_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"· Reading foo.ts"* ]]
}

@test "agent_pretty prints init session header" {
  json='{"type":"system","subtype":"init","session_id":"abc12345-def-ghi","model":"claude-fable-5"}'
  out=$(printf '%s\n' "$json" | agent_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"[session abc12345]"* ]]
  [[ "$out" == *"model=claude-fable-5"* ]]
}

@test "agent_pretty prints result summary" {
  json='{"type":"result","num_turns":7,"total_cost_usd":0.034,"duration_ms":12345}'
  out=$(printf '%s\n' "$json" | agent_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"[done]"* ]]
  [[ "$out" == *"turns=7"* ]]
  [[ "$out" == *"cost=\$0.034"* ]]
}

@test "agent_pretty emits ANSI color codes for tool_use" {
  json='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}]}}'
  out=$(printf '%s\n' "$json" | agent_pretty)
  # Cyan name color (\x1b[36m) should be present
  [[ "$out" == *$'\x1b[36m'* ]]
}

@test "agent_pretty drops unknown event types" {
  json='{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}'
  out=$(printf '%s\n' "$json" | agent_pretty)
  [ -z "$out" ]
}

@test "agent_pretty passes through non-JSON lines verbatim" {
  out=$(printf '%s\n' "not json here" | agent_pretty)
  [ "$out" = "not json here" ]
}

@test "agent_pretty handles a mixed multi-line stream" {
  out=$(cat <<'EOF' | agent_pretty | sed $'s/\x1b\\[[0-9;]*m//g'
{"type":"system","subtype":"init","session_id":"abc12345","model":"claude-fable-5"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a.ts"}}]}}
{"type":"system","subtype":"task_progress","description":"Reading /a.ts"}
{"type":"assistant","message":{"content":[{"type":"text","text":"All done."}]}}
{"type":"result","num_turns":2,"total_cost_usd":0.01,"duration_ms":500}
EOF
)
  [[ "$out" == *"[session abc12345]"* ]]
  [[ "$out" == *"→ Read"* ]]
  [[ "$out" == *"· Reading /a.ts"* ]]
  [[ "$out" == *"All done."* ]]
  [[ "$out" == *"[done]"* ]]
}

# --- codex_pretty: renders codex's `--json` JSONL stream -----------------------

@test "codex_pretty renders agent_message text" {
  json='{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"a real finding"}}'
  out=$(printf '%s\n' "$json" | codex_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"a real finding"* ]]
}

@test "codex_pretty shows command_execution as arrow + command on start" {
  json='{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"/bin/zsh -lc pwd","status":"in_progress"}}'
  out=$(printf '%s\n' "$json" | codex_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"→"* ]]
  [[ "$out" == *"/bin/zsh -lc pwd"* ]]
}

@test "codex_pretty does not repeat the command on a successful completion" {
  json='{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"echo hi","aggregated_output":"hi\n","exit_code":0,"status":"completed"}}'
  out=$(printf '%s\n' "$json" | codex_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [ -z "${out//[[:space:]]/}" ]
}

@test "codex_pretty flags a non-zero command exit" {
  json='{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"false","exit_code":2,"status":"completed"}}'
  out=$(printf '%s\n' "$json" | codex_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"exit 2"* ]]
}

@test "codex_pretty prints turn.completed token summary" {
  json='{"type":"turn.completed","usage":{"input_tokens":120,"output_tokens":34}}'
  out=$(printf '%s\n' "$json" | codex_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"[done]"* ]]
  [[ "$out" == *"out=34"* ]]
}

@test "codex_pretty prints a short thread header" {
  json='{"type":"thread.started","thread_id":"019e924f-134f-7090-a391-7533cba689ae"}'
  out=$(printf '%s\n' "$json" | codex_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"019e924f"* ]]
}

@test "codex_pretty drops unknown / noise event types" {
  json='{"type":"turn.started"}'
  out=$(printf '%s\n' "$json" | codex_pretty)
  [ -z "$out" ]
}

@test "codex_pretty passes through non-JSON lines verbatim" {
  out=$(printf '%s\n' "Reading prompt from stdin..." | codex_pretty)
  [ "$out" = "Reading prompt from stdin..." ]
}

@test "codex_pretty handles a mixed multi-line stream" {
  out=$(cat <<'EOF' | codex_pretty | sed $'s/\x1b\\[[0-9;]*m//g'
{"type":"thread.started","thread_id":"019e924f-1234"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"Checking the diff."}}
{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"git diff","status":"in_progress"}}
{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"git diff","aggregated_output":"...","exit_code":0,"status":"completed"}}
{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":20}}
EOF
)
  [[ "$out" == *"019e924f"* ]]
  [[ "$out" == *"Checking the diff."* ]]
  [[ "$out" == *"→"* ]]
  [[ "$out" == *"git diff"* ]]
  [[ "$out" == *"[done]"* ]]
}
