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

# linear_fetch_via_api <TICKET_ID> <out_json_path>
# Direct REST/GraphQL fetch using $LINEAR_API_KEY. Workspace-portable: works
# against whatever workspace the key authorizes, regardless of which workspace
# the agent's Linear MCP is connected to. Schema matches what
# prompts/01-worktree-fetch.md documents: identifier, title, description,
# state, url, team.
linear_fetch_via_api() {
  local ticket="$1" out="$2"
  local body resp tmp
  body=$(jq -n --arg id "$ticket" '{
    query: "query($id:String!){issue(id:$id){identifier title description url state{name type} team{key name}}}",
    variables: {id: $id}
  }')
  resp=$(curl -sS --max-time 15 -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    --data "$body") || { log_err "Linear API request failed for $ticket"; return 1; }

  if echo "$resp" | jq -e '.errors' >/dev/null 2>&1; then
    log_err "Linear API returned errors: $(echo "$resp" | jq -c '.errors')"
    return 1
  fi

  if [[ "$(echo "$resp" | jq -r '.data.issue // empty')" == "" ]]; then
    log_err "Linear API: ticket '$ticket' not found (or not visible to this API key)"
    return 1
  fi

  tmp=$(mktemp)
  echo "$resp" | jq '.data.issue' > "$tmp"
  mv -f "$tmp" "$out"
}

# linear_fetch <TICKET_ID> <out_json_path>
# Prefers the REST API path when LINEAR_API_KEY is set (workspace-portable).
# Falls back to the agent's Linear MCP otherwise.
linear_fetch() {
  local ticket="$1" out="$2"
  mkdir -p "$(dirname "$out")" "${WT}/.autopilot/logs"

  if [[ -n "${LINEAR_API_KEY:-}" ]]; then
    set_term_title "${ticket} · linear-fetch (api)"
    if linear_fetch_via_api "$ticket" "$out"; then
      return 0
    fi
    log_warn "Linear API fetch failed for $ticket; falling back to agent MCP"
  fi

  local rendered="${WT}/.autopilot/prompts/01-worktree-fetch.md"
  mkdir -p "$(dirname "$rendered")"
  TICKET="$ticket" OUT="$out" render_prompt \
    "${AUTOPILOT_ROOT}/prompts/01-worktree-fetch.md" "$rendered"
  set_term_title "${ticket} · linear-fetch (mcp)"
  # shellcheck disable=SC2086
  ( cd "$WT" && eval $AUTOPILOT_AGENT_CMD ) < "$rendered" 2>&1 \
    | tee "$WT/.autopilot/logs/01-worktree-fetch.log" \
    | agent_pretty
  if [[ ! -s "$out" ]]; then
    log_err "Linear fetch did not produce $out. Check that the agent's Linear MCP is installed and authenticated, or set LINEAR_API_KEY for the REST path."
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
