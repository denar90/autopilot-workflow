#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/ui.sh"
  source "$LIB_DIR/agent.sh"
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
  json='{"type":"system","subtype":"init","session_id":"abc12345-def-ghi","model":"claude-opus-4-7"}'
  out=$(printf '%s\n' "$json" | agent_pretty | sed $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" == *"[session abc12345]"* ]]
  [[ "$out" == *"model=claude-opus-4-7"* ]]
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
{"type":"system","subtype":"init","session_id":"abc12345","model":"claude-opus-4-7"}
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
