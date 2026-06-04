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

# plan_seed_worktree <wt> <plan_src> <slug>
# Seed an already-created worktree dir for plan-file mode: install the state and
# feedback templates, copy the plan to .autopilot/plan.md (kept out of the tracked
# tree so it never lands in the review diff), and write research.md + ticket.json
# stubs so the implement, review, codex, and merge/pr phases run unchanged. Pure
# file ops — no git. Requires lib/state.sh sourced and $AUTOPILOT_ROOT set.
plan_seed_worktree() {
  local wt="$1" plan_src="$2" slug="$3"
  export WT="$wt"

  mkdir -p "$WT/.autopilot/prompts" "$WT/.autopilot/logs"
  [[ -f "$WT/.autopilot/state.json" ]] \
    || cp "$AUTOPILOT_ROOT/templates/state.json" "$WT/.autopilot/state.json"
  [[ -f "$WT/.autopilot/feedback.json" ]] \
    || cp "$AUTOPILOT_ROOT/templates/feedback.json" "$WT/.autopilot/feedback.json"

  cp "$plan_src" "$WT/.autopilot/plan.md"

  # The research/plan phases are skipped in plan-file mode; leave a breadcrumb the
  # implement prompt reads in place of a real research.md.
  cat > "$WT/.autopilot/research.md" <<EOF
# Research

Plan-file mode: an implementation plan was supplied directly
($(basename "$plan_src")), so the research and planning phases were skipped.
See \`.autopilot/plan.md\` for the plan and its rationale.
EOF

  # Stub ticket.json so phase06 (merge/pr) and the review/codex prompts — which
  # read identifier/title/url — work without a Linear ticket.
  local ticket_tmp; ticket_tmp=$(mktemp)
  jq -n --arg s "$slug" --arg f "$(basename "$plan_src")" \
    '{identifier:$s, title:$s, description:("Autopilot plan-file run from " + $f), url:""}' \
    > "$ticket_tmp"
  mv -f "$ticket_tmp" "$WT/.autopilot/ticket.json"

  state_set ticket "$slug"
  state_set worktree "$WT"
  state_set branch "$(plan_branch_name "$slug")"
  state_set plan_path ".autopilot/plan.md"
}
