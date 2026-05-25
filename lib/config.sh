#!/usr/bin/env bash
# Config loader. Precedence: caller env > .autopilotrc > defaults.

config_load() {
  : "${AUTOPILOT_WORKTREE_BASE:=$HOME/wt}"
  : "${AUTOPILOT_MODEL:=claude-opus-4-7}"
  : "${AUTOPILOT_AGENT_CMD:=claude -p --output-format=stream-json --verbose --permission-mode bypassPermissions --model $AUTOPILOT_MODEL}"
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

# default_branch [<repo-dir>]
# Returns the remote's default branch (main, master, trunk, etc.), determined
# by `git symbolic-ref refs/remotes/origin/HEAD`. Falls back to `main` if
# origin/HEAD isn't set (rare — most clones have it). Pass a repo dir or rely
# on $PWD.
default_branch() {
  local repo="${1:-$PWD}" b
  b=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@') || true
  if [[ -z "$b" ]]; then
    # Try refreshing origin/HEAD from the remote (one-time cost per worktree).
    git -C "$repo" remote set-head origin --auto >/dev/null 2>&1 || true
    b=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@') || true
  fi
  echo "${b:-main}"
}
