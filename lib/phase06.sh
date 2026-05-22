#!/usr/bin/env bash
# Phase 06: merge / pr / preview / hold.

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
  local branch base ticket ticket_url head_sha pr_url=""
  branch=$(jq -r .branch "$WT/.autopilot/state.json")
  base=$(git -C "$WT" merge-base origin/main HEAD)
  ticket=$(jq -r '.identifier // .ticket // empty' "$WT/.autopilot/ticket.json" 2>/dev/null)
  ticket_url=$(jq -r '.url // empty' "$WT/.autopilot/ticket.json" 2>/dev/null)
  head_sha=$(git -C "$WT" rev-parse HEAD)

  case "${_AUTOPILOT_REVIEW_DECISION:-hold}" in
    merge)
      ( cd "$WT" && git checkout main && git pull --ff-only && \
        git merge --no-ff "$branch" -m "merge: $branch" && \
        git push origin main )
      emit_ready_file "$ticket" "$branch" merge "$ticket_url" "" "$base" "$head_sha" "$WT"
      ;;
    pr)
      export BASE_SHA="$base"
      run_phase 06-pr-body || return 1
      local body="$WT/.autopilot/pr-body.md"
      ( cd "$WT" && git push -u origin "$branch" && \
        gh pr create --title "$(jq -r .title "$WT/.autopilot/ticket.json")" \
                     --body-file "$body" )
      pr_url=$(cd "$WT" && gh pr view "$branch" --json url -q .url 2>/dev/null || echo "")
      emit_ready_file "$ticket" "$branch" pr "$ticket_url" "$pr_url" "$base" "$head_sha" "$WT"
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
