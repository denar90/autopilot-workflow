#!/usr/bin/env bash
# Linear URL parsing and ticket fetch helpers.

linear_parse_ticket() {
  local input="${1:-}"
  [[ -z "$input" ]] && return 1
  local id=""
  if [[ "$input" =~ ^[A-Za-z]+-[0-9]+$ ]]; then
    id="$input"
  elif [[ "$input" =~ /issue/([A-Za-z]+-[0-9]+) ]]; then
    id="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  echo "$id" | tr '[:lower:]' '[:upper:]'
}

linear_parse_slug() {
  local input="${1:-}"
  if [[ "$input" =~ /issue/[A-Za-z]+-[0-9]+/([A-Za-z0-9._-]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# linear_fetch <TICKET_ID> <out_json_path>
# Routes through the agent's Linear MCP. Agent must have Linear MCP configured.
linear_fetch() {
  local ticket="$1" out="$2"
  local rendered="${WT}/.autopilot/prompts/01-worktree-fetch.md"
  mkdir -p "$(dirname "$rendered")" "${WT}/.autopilot/logs"
  TICKET="$ticket" OUT="$out" render_prompt \
    "${AUTOPILOT_ROOT}/prompts/01-worktree-fetch.md" "$rendered"
  set_term_title "${ticket} · linear-fetch"
  # shellcheck disable=SC2086
  ( cd "$WT" && eval $AUTOPILOT_AGENT_CMD ) < "$rendered" 2>&1 \
    | tee "$WT/.autopilot/logs/01-worktree-fetch.log" \
    | agent_pretty
  if [[ ! -s "$out" ]]; then
    log_err "Linear fetch did not produce $out. Check that the agent's Linear MCP is installed and authenticated."
    return 1
  fi
  state_add_cost "$WT/.autopilot/logs/01-worktree-fetch.log"
}

linear_branch_name() {
  local ticket
  ticket=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  local slug="${2:-}"
  if [[ -z "$slug" ]]; then
    echo "feature/${ticket}"
  else
    echo "feature/${ticket}-${slug}"
  fi
}
