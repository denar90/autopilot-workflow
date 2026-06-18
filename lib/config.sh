#!/usr/bin/env bash
# Config loader. Precedence: caller env > .autopilotrc > defaults.

config_load() {
  : "${AUTOPILOT_WORKTREE_BASE:=$HOME/wt}"
  : "${AUTOPILOT_MODEL:=claude-opus-4-8}"
  : "${AUTOPILOT_AGENT_CMD:=claude -p --output-format=stream-json --verbose --permission-mode bypassPermissions --model $AUTOPILOT_MODEL}"
  # Review-cycle phases (reviewer/adversary/fixer) run on a cheaper model than the
  # primary implement/plan model — they critique and patch an existing diff, which
  # doesn't need the frontier tier. This is the main cost lever for the 05x loop.
  : "${AUTOPILOT_MODEL_REVIEW:=claude-opus-4-8}"
  : "${AUTOPILOT_AGENT_CMD_REVIEW:=claude -p --output-format=stream-json --verbose --permission-mode bypassPermissions --model $AUTOPILOT_MODEL_REVIEW}"
  : "${AUTOPILOT_CODEX_CMD:=codex exec --json --full-auto}"
  : "${AUTOPILOT_SETUP_CMD:=}"
  : "${AUTOPILOT_VERIFY_CMD:=make check test}"
  : "${AUTOPILOT_SYMLINKS:=}"
  : "${AUTOPILOT_MODE:=interactive}"
  : "${AUTOPILOT_DEFAULT_ACTION:=pr}"
  # Visual verification: auto (run, but the agent skips non-UI work) | on (always) | off.
  : "${AUTOPILOT_VISUAL:=auto}"
  # Command to launch the app for visual verification. Empty → the agent uses the
  # project's run skill / dev script.
  : "${AUTOPILOT_APP_CMD:=}"

  # Load .autopilotrc from the repo root (so running from a subdirectory still
  # picks it up), falling back to the current directory when not in a git repo.
  local rc=".autopilotrc" top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || true
  [[ -n "$top" && -f "$top/.autopilotrc" ]] && rc="$top/.autopilotrc"
  if [[ -f "$rc" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$rc"
  fi

  export AUTOPILOT_WORKTREE_BASE AUTOPILOT_MODEL AUTOPILOT_AGENT_CMD \
         AUTOPILOT_MODEL_REVIEW AUTOPILOT_AGENT_CMD_REVIEW \
         AUTOPILOT_CODEX_CMD \
         AUTOPILOT_SETUP_CMD AUTOPILOT_VERIFY_CMD AUTOPILOT_SYMLINKS \
         AUTOPILOT_MODE AUTOPILOT_DEFAULT_ACTION \
         AUTOPILOT_VISUAL AUTOPILOT_APP_CMD
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

# remote_exists [<repo-dir>] — true when an `origin` remote is configured.
# Autopilot works on local-only repos (no remote): worktrees branch from the
# local default branch and the final push/PR is skipped.
remote_exists() {
  git -C "${1:-$PWD}" remote get-url origin >/dev/null 2>&1
}

# default_branch [<repo-dir>]
# Returns the default branch (main, master, trunk, etc.). With an origin remote
# it uses `git symbolic-ref refs/remotes/origin/HEAD`. For a local-only repo it
# falls back to a local `main`/`master`, then the current branch. Pass a repo dir
# or rely on $PWD.
default_branch() {
  local repo="${1:-$PWD}" b
  b=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@') || true
  if [[ -z "$b" ]] && remote_exists "$repo"; then
    # Try refreshing origin/HEAD from the remote (one-time cost per worktree).
    git -C "$repo" remote set-head origin --auto >/dev/null 2>&1 || true
    b=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@') || true
  fi
  if [[ -z "$b" ]]; then
    # No origin/HEAD (local-only repo): prefer a local main/master, else the
    # current branch.
    if git -C "$repo" show-ref --verify --quiet refs/heads/main; then b=main
    elif git -C "$repo" show-ref --verify --quiet refs/heads/master; then b=master
    else b=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null) || true; fi
  fi
  echo "${b:-main}"
}

# base_ref [<repo-dir>] — the ref new work branches from and review diffs against.
# `origin/<default-branch>` when an origin remote exists, otherwise the local
# `<default-branch>`. Centralizes the remote-vs-local choice for worktree creation,
# review base, and commit counting.
base_ref() {
  local repo="${1:-$PWD}" b
  b=$(default_branch "$repo")
  if remote_exists "$repo"; then printf 'origin/%s' "$b"; else printf '%s' "$b"; fi
}

# visual_enabled — true unless AUTOPILOT_VISUAL=off. (`auto` and `on` both run the
# phase; the auto-vs-on self-gate is decided inside the visual-verify prompt.)
visual_enabled() {
  [[ "${AUTOPILOT_VISUAL:-auto}" != "off" ]]
}
