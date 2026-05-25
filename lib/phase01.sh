#!/usr/bin/env bash
# Phase 01: bash-driven worktree creation.

phase01_worktree() {
  local linear_input="$1"
  local source_repo="$2"

  local ticket slug branch project ticket_lc wt
  ticket=$(linear_parse_ticket "$linear_input") || { log_err "Bad Linear input"; return 1; }
  slug=$(linear_parse_slug "$linear_input")
  branch=$(linear_branch_name "$ticket" "$slug")
  project=$(cd "$source_repo" && config_project_name)
  ticket_lc=$(echo "$ticket" | tr '[:upper:]' '[:lower:]')
  wt="${AUTOPILOT_WORKTREE_BASE}/${project}/${ticket_lc}"

  export WT="$wt"
  log_info "Worktree target: $WT"
  log_info "Branch:          $branch"
  log_info "Source repo:     $source_repo"

  if [[ -d "$WT" ]]; then
    log_warn "Worktree dir already exists — assuming resume; skipping git worktree add"
  else
    local base; base=$(default_branch "$source_repo")
    ( cd "$source_repo" && git fetch origin "$base" )
    ( cd "$source_repo" && git worktree add "$WT" -b "$branch" "origin/$base" )
  fi

  mkdir -p "$WT/.autopilot/prompts" "$WT/.autopilot/logs"
  [[ -f "$WT/.autopilot/state.json" ]] \
    || cp "$AUTOPILOT_ROOT/templates/state.json" "$WT/.autopilot/state.json"
  [[ -f "$WT/.autopilot/feedback.json" ]] \
    || cp "$AUTOPILOT_ROOT/templates/feedback.json" "$WT/.autopilot/feedback.json"

  if [[ -n "$AUTOPILOT_SYMLINKS" ]]; then
    while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      local src="$source_repo/$rel"
      local dst="$WT/$rel"
      if [[ -e "$src" && ! -e "$dst" ]]; then
        mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst"
        log_info "Symlinked $rel"
      fi
    done <<< "$AUTOPILOT_SYMLINKS"
  fi

  linear_fetch "$ticket" "$WT/.autopilot/ticket.json"

  state_set ticket "$ticket"
  state_set worktree "$WT"
  state_set branch "$branch"

  if [[ -n "${AUTOPILOT_SETUP_CMD:-}" ]]; then
    log_info "Running setup: $AUTOPILOT_SETUP_CMD"
    ( cd "$WT" && eval "$AUTOPILOT_SETUP_CMD" ) || { log_err "Setup failed"; return 1; }
  fi
}
