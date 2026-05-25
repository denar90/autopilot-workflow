#!/usr/bin/env bash
# Interactive checkpoints. Reads from /dev/tty so checkpoints work when stdout
# is piped to tee. Honors $AUTOPILOT_MODE (interactive|full).

_ask() {
  local prompt="$1" reply=""
  printf "%s " "$prompt" > /dev/tty
  IFS= read -r reply < /dev/tty
  echo "$reply"
}

# checkpoint_plan <plan_path>
checkpoint_plan() {
  local plan="$1"
  if [[ "${AUTOPILOT_MODE:-interactive}" == "full" ]]; then
    log_info "Plan auto-approved (full mode)."
    return 0
  fi
  set_term_title "${TICKET:-autopilot} · plan ✋"
  print_tldr "$plan"
  while :; do
    local ans
    ans=$(_ask "Proceed? [go / changes / stop]")
    case "$ans" in
      go)      return 0 ;;
      changes*)
        local fb="${ans#changes}"
        fb="${fb# }"
        [[ -z "$fb" ]] && fb=$(_ask "What should change?")
        log_info "Re-running plan with feedback: $fb"
        FEEDBACK="$fb" run_phase 03-plan || return 1
        print_tldr "$plan"
        ;;
      stop)    log_info "Stopping at plan checkpoint."; exit 0 ;;
      *)       log_warn "Unknown response: $ans" ;;
    esac
  done
}

# checkpoint_review <branch> <commit_count>
checkpoint_review() {
  local branch="$1" commits="$2"
  set_term_title "${TICKET:-autopilot} · review ✋"
  feedback_summary "$WT/.autopilot/feedback.json"
  echo
  echo "Branch:  $branch"
  echo "Commits: $commits"

  if [[ "${AUTOPILOT_MODE:-interactive}" == "full" ]]; then
    local act="${AUTOPILOT_DEFAULT_ACTION:-pr}"
    log_info "Review auto-action (full mode): $act"
    _AUTOPILOT_REVIEW_DECISION="$act"
    export _AUTOPILOT_REVIEW_DECISION
    return 0
  fi

  while :; do
    local ans
    ans=$(_ask "Action? [merge / pr / preview / hold]")
    case "$ans" in
      merge|pr|preview|hold)
        _AUTOPILOT_REVIEW_DECISION="$ans"
        export _AUTOPILOT_REVIEW_DECISION
        return 0
        ;;
      *) log_warn "Unknown response: $ans" ;;
    esac
  done
}
