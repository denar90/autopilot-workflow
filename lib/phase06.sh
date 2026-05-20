#!/usr/bin/env bash
# Phase 06: merge / pr / preview / hold.

phase06_merge_or_pr() {
  local branch base
  branch=$(jq -r .branch "$WT/.autopilot/state.json")
  base=$(git -C "$WT" merge-base origin/main HEAD)

  case "${_AUTOPILOT_REVIEW_DECISION:-hold}" in
    merge)
      ( cd "$WT" && git checkout main && git pull --ff-only && \
        git merge --no-ff "$branch" -m "merge: $branch" && \
        git push origin main )
      ;;
    pr)
      export BASE_SHA="$base"
      run_phase 06-pr-body || return 1
      local body="$WT/.autopilot/pr-body.md"
      ( cd "$WT" && git push -u origin "$branch" && \
        gh pr create --title "$(jq -r .title "$WT/.autopilot/ticket.json")" \
                     --body-file "$body" )
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
