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

@test "config_load sources .autopilotrc from the repo root when run from a subdir" {
  git init -q
  echo 'AUTOPILOT_VERIFY_CMD="from-root"' > .autopilotrc
  mkdir -p sub/deep
  cd sub/deep
  config_load
  [ "${AUTOPILOT_VERIFY_CMD}" = "from-root" ]
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

@test "config_load defaults AUTOPILOT_REVIEW_CYCLES to 1 (one round)" {
  config_load
  [ "${AUTOPILOT_REVIEW_CYCLES}" = "1" ]
}

@test "config_load clamps AUTOPILOT_REVIEW_CYCLES above 3 to 3" {
  export AUTOPILOT_REVIEW_CYCLES=9
  config_load
  [ "${AUTOPILOT_REVIEW_CYCLES}" = "3" ]
}

@test "config_load clamps non-numeric / below-1 AUTOPILOT_REVIEW_CYCLES to 1" {
  export AUTOPILOT_REVIEW_CYCLES=abc
  config_load
  [ "${AUTOPILOT_REVIEW_CYCLES}" = "1" ]
  export AUTOPILOT_REVIEW_CYCLES=0
  config_load
  [ "${AUTOPILOT_REVIEW_CYCLES}" = "1" ]
}

@test "config_load preserves a valid in-range AUTOPILOT_REVIEW_CYCLES" {
  export AUTOPILOT_REVIEW_CYCLES=3
  config_load
  [ "${AUTOPILOT_REVIEW_CYCLES}" = "3" ]
}

@test "config_load defaults AUTOPILOT_VISUAL to auto" {
  config_load
  [ "${AUTOPILOT_VISUAL}" = "auto" ]
}

@test "config_load defaults AUTOPILOT_APP_CMD to empty" {
  config_load
  [ -z "${AUTOPILOT_APP_CMD}" ]
}

@test "config_load preserves caller-set AUTOPILOT_VISUAL" {
  export AUTOPILOT_VISUAL="off"
  config_load
  [ "${AUTOPILOT_VISUAL}" = "off" ]
}

@test "visual_enabled true for auto and on, false for off" {
  AUTOPILOT_VISUAL=auto visual_enabled
  AUTOPILOT_VISUAL=on   visual_enabled
  ! AUTOPILOT_VISUAL=off visual_enabled
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

# --- remote_exists / local-repo support ---------------------------------------

@test "remote_exists is false without an origin remote" {
  git init -q
  run remote_exists
  [ "$status" -ne 0 ]
}

@test "remote_exists is true with an origin remote" {
  git init -q
  git remote add origin git@github.com:foo/bar.git
  run remote_exists
  [ "$status" -eq 0 ]
}

# portable git init on an explicit initial branch (git < 2.28 has no `init -b`)
_git_init_on() {
  git init -q
  git symbolic-ref HEAD "refs/heads/$1"
  git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init
}

@test "default_branch falls back to local main without an origin remote" {
  _git_init_on main
  run default_branch
  [ "$output" = "main" ]
}

@test "default_branch uses local master when that is the default and no origin" {
  _git_init_on master
  run default_branch
  [ "$output" = "master" ]
}

@test "default_branch uses the current branch when no origin and no main/master" {
  _git_init_on dev
  run default_branch
  [ "$output" = "dev" ]
}

@test "base_ref is the local default branch without an origin remote" {
  _git_init_on main
  run base_ref
  [ "$output" = "main" ]
}

@test "base_ref is origin-qualified when an origin remote exists" {
  _git_init_on main
  git remote add origin git@github.com:foo/bar.git
  run base_ref
  [ "$output" = "origin/main" ]
}
