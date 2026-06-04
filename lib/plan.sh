#!/usr/bin/env bash
# Plan-file mode: run an existing implementation plan directly, skipping the
# Linear ticket fetch, research, and plan-generation phases. The user supplies a
# plan file; autopilot creates an isolated worktree, seeds it, and resumes at
# the implement phase. Requires $WT-independent helpers + lib/ui.sh sourced.

# is_plan_input <arg> — true when <arg> should be treated as a plan file rather
# than a Linear URL/ID: it ends in `.md`, or it names an existing file. A Linear
# identifier ("TRA-550") or URL matches neither.
is_plan_input() {
  case "$1" in
    *.md) return 0 ;;
  esac
  [[ -f "$1" ]]
}

# plan_slug <path> — derive a slug from a plan filename: strip the directory,
# the `.md` extension, and a leading `YYYY-MM-DD-` date prefix if present.
#   docs/plans/2026-06-04-shared-app-sidebar.md  ->  shared-app-sidebar
plan_slug() {
  local b
  b=$(basename "$1")
  b="${b%.md}"
  printf '%s' "$b" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//'
}

# plan_branch_name <slug> — branch name for plan-file mode.
plan_branch_name() {
  printf 'feature/%s' "$1"
}
