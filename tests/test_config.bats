#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  cd "$TMP"
  source "$LIB_DIR/config.sh"
}

teardown() {
  rm -rf "$TMP"
}

@test "config_load applies defaults when no .autopilotrc present" {
  config_load
  [ "${AUTOPILOT_WORKTREE_BASE}" = "$HOME/wt" ]
  [ -n "${AUTOPILOT_AGENT_CMD}" ]
  [ -n "${AUTOPILOT_VERIFY_CMD}" ]
  [ "${AUTOPILOT_MODE}" = "interactive" ]
  [ "${AUTOPILOT_DEFAULT_ACTION}" = "pr" ]
}

@test "config_load sources local .autopilotrc when present" {
  cat > .autopilotrc <<EOF
AUTOPILOT_WORKTREE_BASE="/tmp/custom-wt"
AUTOPILOT_VERIFY_CMD="echo custom"
EOF
  config_load
  [ "${AUTOPILOT_WORKTREE_BASE}" = "/tmp/custom-wt" ]
  [ "${AUTOPILOT_VERIFY_CMD}" = "echo custom" ]
}

@test "config_load preserves caller-set env overrides" {
  export AUTOPILOT_WORKTREE_BASE="/override"
  config_load
  [ "${AUTOPILOT_WORKTREE_BASE}" = "/override" ]
}

@test "config_load defaults AUTOPILOT_MODEL to claude-opus-4-8" {
  config_load
  [ "${AUTOPILOT_MODEL}" = "claude-opus-4-8" ]
}

@test "config_load threads AUTOPILOT_MODEL into AUTOPILOT_AGENT_CMD" {
  config_load
  [[ "${AUTOPILOT_AGENT_CMD}" == *"claude-opus-4-8"* ]]
}

@test "config_load defaults AUTOPILOT_MODEL_REVIEW to claude-opus-4-8" {
  config_load
  [ "${AUTOPILOT_MODEL_REVIEW}" = "claude-opus-4-8" ]
}

@test "config_load threads AUTOPILOT_MODEL_REVIEW into AUTOPILOT_AGENT_CMD_REVIEW" {
  config_load
  [[ "${AUTOPILOT_AGENT_CMD_REVIEW}" == *"claude-opus-4-8"* ]]
}

@test "config_load preserves caller-set AUTOPILOT_MODEL_REVIEW" {
  export AUTOPILOT_MODEL_REVIEW="claude-haiku-4-5"
  config_load
  [ "${AUTOPILOT_MODEL_REVIEW}" = "claude-haiku-4-5" ]
  [[ "${AUTOPILOT_AGENT_CMD_REVIEW}" == *"claude-haiku-4-5"* ]]
}

@test "config_load defaults AUTOPILOT_CODEX_CMD to a codex invocation" {
  config_load
  [ "${AUTOPILOT_CODEX_CMD}" = "codex exec --json --full-auto" ]
}

@test "config_load preserves caller-set AUTOPILOT_CODEX_CMD" {
  export AUTOPILOT_CODEX_CMD="codex --custom"
  config_load
  [ "${AUTOPILOT_CODEX_CMD}" = "codex --custom" ]
}

@test "config_project_name uses git remote when available" {
  git init -q
  git remote add origin git@github.com:foo/my-cool-repo.git
  run config_project_name
  [ "$output" = "my-cool-repo" ]
}

@test "config_project_name falls back to dir basename without remote" {
  git init -q
  run config_project_name
  [ -n "$output" ]
}
