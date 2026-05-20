#!/usr/bin/env bash
# Config loader. Precedence: caller env > .autopilotrc > defaults.

config_load() {
  : "${AUTOPILOT_WORKTREE_BASE:=$HOME/wt}"
  : "${AUTOPILOT_MODEL:=claude-opus-4-7}"
  : "${AUTOPILOT_AGENT_CMD:=claude -p --output-format=stream-json --model $AUTOPILOT_MODEL}"
  : "${AUTOPILOT_SETUP_CMD:=}"
  : "${AUTOPILOT_VERIFY_CMD:=make check test}"
  : "${AUTOPILOT_SYMLINKS:=}"
  : "${AUTOPILOT_MODE:=interactive}"
  : "${AUTOPILOT_DEFAULT_ACTION:=pr}"

  if [[ -f .autopilotrc ]]; then
    # shellcheck disable=SC1091
    source .autopilotrc
  fi

  export AUTOPILOT_WORKTREE_BASE AUTOPILOT_MODEL AUTOPILOT_AGENT_CMD \
         AUTOPILOT_SETUP_CMD AUTOPILOT_VERIFY_CMD AUTOPILOT_SYMLINKS \
         AUTOPILOT_MODE AUTOPILOT_DEFAULT_ACTION
}

config_project_name() {
  local url name
  if url=$(git config --get remote.origin.url 2>/dev/null) && [[ -n "$url" ]]; then
    name="${url##*/}"
    name="${name%.git}"
    echo "$name"
  else
    basename "$PWD"
  fi
}
