#!/usr/bin/env bash
# UI helpers: colored logging, summary tables.

_ts() { date +"%H:%M:%S"; }

log_info()  { printf "\033[1;36m[%s]\033[0m %s\n" "$(_ts)" "$*"; }

# set_term_title <title> — updates the terminal tab/window title via OSC 0.
# No-op when stderr isn't a tty (e.g. piped, CI).
set_term_title() {
  [[ -t 2 ]] || return 0
  printf '\033]0;%s\007' "$*" >&2
}
log_warn()  { printf "\033[1;33m[%s]\033[0m %s\n" "$(_ts)" "$*" >&2; }
log_err()   { printf "\033[1;31m[%s]\033[0m %s\n" "$(_ts)" "$*" >&2; }
log_ok()    { printf "\033[1;32m[%s]\033[0m %s\n" "$(_ts)" "$*"; }

# print_tldr <plan_path>
print_tldr() {
  local plan="$1"
  [[ -f "$plan" ]] || { log_err "Plan not found: $plan"; return 1; }
  echo "── Plan TLDR ───────────────────────────────"
  awk '/^## Task / { exit } { print }' "$plan" | sed -n '1,40p'
  echo "────────────────────────────────────────────"
}

# feedback_summary <feedback.json>
feedback_summary() {
  local f="$1"
  [[ -f "$f" ]] || { log_err "Feedback not found: $f"; return 1; }
  echo "── Review summary ──────────────────────────"
  jq -r '
    .items
    | group_by(.severity)[]
    | "\(.[0].severity): " +
      "open=" + (map(select(.status=="open"))|length|tostring) + " " +
      "fixed=" + (map(select(.status=="fixed"))|length|tostring) + " " +
      "dropped=" + (map(select(.status=="dropped_by_adversary"))|length|tostring) + " " +
      "wontfix=" + (map(select(.status=="wontfix"))|length|tostring)
  ' "$f"
  echo "────────────────────────────────────────────"
}
