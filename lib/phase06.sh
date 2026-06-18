#!/usr/bin/env bash
# Phase 06: merge / pr / preview / hold.

# gh_available: succeeds when `gh` CLI is installed AND authenticated.
gh_available() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1
}

# emit_ready_file <ticket> <branch> <action> <ticketUrl> <prUrl> <baseSha> <headSha> <worktree>
# Writes a .ready.json into $AUTOPILOT_QUEUE_DIR for the autopilot-pipeline
# daemon to consume. No-op when AUTOPILOT_QUEUE_DIR is unset.
emit_ready_file() {
  [[ -n "${AUTOPILOT_QUEUE_DIR:-}" ]] || return 0
  mkdir -p "$AUTOPILOT_QUEUE_DIR"
  local ticket="$1" branch="$2" action="$3" ticketUrl="$4" prUrl="$5" baseSha="$6" headSha="$7" wt="$8"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local paths_json="[]"
  if [[ -d "$wt/.git" || -d "$wt" ]] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    paths_json=$(git -C "$wt" diff --name-only "$baseSha..$headSha" 2>/dev/null \
                  | jq -R . | jq -s .) || paths_json="[]"
  fi
  jq -n \
    --arg t "$ticket" --arg tu "$ticketUrl" --arg b "$branch" \
    --arg a "$action" --arg pr "$prUrl" --arg bs "$baseSha" \
    --arg hs "$headSha" --arg w "$wt" --arg now "$now" \
    --argjson paths "$paths_json" \
    '{ticket:$t,ticketUrl:$tu,branch:$b,actionTaken:$a,prUrl:$pr,changedPaths:$paths,baseSha:$bs,headSha:$hs,worktree:$w,completedAt:$now}' \
    > "$AUTOPILOT_QUEUE_DIR/$ticket.ready.json.tmp"
  mv -f "$AUTOPILOT_QUEUE_DIR/$ticket.ready.json.tmp" "$AUTOPILOT_QUEUE_DIR/$ticket.ready.json"
}

phase06_merge_or_pr() {
  local branch base ticket ticket_url head_sha pr_url="" main_branch action
  branch=$(jq -r .branch "$WT/.autopilot/state.json")
  main_branch=$(default_branch "$WT")
  base=$(git -C "$WT" merge-base "$(base_ref "$WT")" HEAD)
  ticket=$(jq -r '.identifier // .ticket // empty' "$WT/.autopilot/ticket.json" 2>/dev/null)
  ticket_url=$(jq -r '.url // empty' "$WT/.autopilot/ticket.json" 2>/dev/null)
  head_sha=$(git -C "$WT" rev-parse HEAD)
  action="${_AUTOPILOT_REVIEW_DECISION:-hold}"

  # merge/pr/preview all need an origin remote. On a local-only repo, skip the
  # push and leave the work on its branch for manual integration.
  if [[ "$action" != "hold" ]] && ! remote_exists "$WT"; then
    log_warn "No 'origin' remote — cannot '$action'. Work is committed on branch '$branch'."
    log_info "Integrate it with: git -C \"$WT\" push -u origin \"$branch\"  (after adding a remote), or merge locally."
    emit_ready_file "$ticket" "$branch" hold "$ticket_url" "" "$base" "$head_sha" "$WT"
    return 0
  fi

  case "$action" in
    merge)
      ( cd "$WT" && git checkout "$main_branch" && git pull --ff-only && \
        git merge --no-ff "$branch" -m "merge: $branch" && \
        git push origin "$main_branch" )
      emit_ready_file "$ticket" "$branch" merge "$ticket_url" "" "$base" "$head_sha" "$WT"
      ;;
    pr)
      export BASE_SHA="$base"
      run_phase 06-pr-body || return 1
      local body="$WT/.autopilot/pr-body.md"
      if gh_available; then
        ( cd "$WT" && git push -u origin "$branch" && \
          gh pr create --title "$(jq -r .title "$WT/.autopilot/ticket.json")" \
                       --body-file "$body" )
        pr_url=$(cd "$WT" && gh pr view "$branch" --json url -q .url 2>/dev/null || echo "")
        emit_ready_file "$ticket" "$branch" pr "$ticket_url" "$pr_url" "$base" "$head_sha" "$WT"
      else
        log_warn "gh CLI not available or not authenticated — pushing branch only. Open a PR manually."
        ( cd "$WT" && git push -u origin "$branch" )
        log_info "Branch pushed: $branch"
        log_info "PR body drafted at: $body"
        emit_ready_file "$ticket" "$branch" push_only "$ticket_url" "" "$base" "$head_sha" "$WT"
      fi
      ;;
    preview)
      log_info "Preview: branch $branch pushed but not merged."
      ( cd "$WT" && git push -u origin "$branch" )
      ;;
    hold)
      log_info "Hold: nothing to push. Worktree preserved at $WT."
      ;;
  esac
}
