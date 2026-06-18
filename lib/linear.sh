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
    query: "query($id:String!){issue(id:$id){identifier title description url state{name type} team{key name} attachments{nodes{url title}}}}",
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

# linear_extract_image_urls <ticket.json>
# Emit (one per line, deduped) the reference-image URLs for a ticket: images
# embedded in the description (`uploads.linear.app/...` and any `*.png/jpg/...`
# links) plus attachment URLs that look like images. Non-image links (Figma,
# PRs, etc.) are deliberately excluded.
linear_extract_image_urls() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  {
    jq -r '.description // ""' "$f" | grep -oE 'https://uploads\.linear\.app/[^ )"'"'"']+'
    jq -r '.description // ""' "$f" | grep -oiE 'https?://[^ )"'"'"']+\.(png|jpe?g|gif|webp)'
    jq -r '(.attachments.nodes // [])[].url // empty' "$f" 2>/dev/null \
      | grep -oiE 'https?://[^ )"'"'"']+\.(png|jpe?g|gif|webp)'
  } 2>/dev/null | sort -u
}

# linear_fetch_criteria_images <ticket.json> <out-dir>
# Download the ticket's reference images (see linear_extract_image_urls) into
# <out-dir> and record the local paths in <ticket.json> as `.criteria_images`.
# Best-effort: a failed download is warned and skipped, never fatal. Needs
# $LINEAR_API_KEY to authorize uploads.linear.app assets.
linear_fetch_criteria_images() {
  local f="$1" dir="$2" urls n=0 saved=() dest
  urls=$(linear_extract_image_urls "$f")
  [[ -z "$urls" ]] && return 0
  mkdir -p "$dir"
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    n=$((n + 1))
    dest="$dir/criteria-${n}"
    if curl -fsSL --max-time 30 -H "Authorization: ${LINEAR_API_KEY:-}" "$url" -o "$dest" 2>/dev/null; then
      saved+=("$dest")
      log_info "Saved reference image: $dest"
    else
      log_warn "Could not download reference image: $url"
    fi
  done <<< "$urls"
  if [[ ${#saved[@]} -gt 0 ]]; then
    local tmp; tmp=$(mktemp)
    printf '%s\n' "${saved[@]}" | jq -R . | jq -s --slurpfile t <(cat "$f") \
      '$t[0] + {criteria_images: .}' > "$tmp" && mv -f "$tmp" "$f"
  fi
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
  else
    log_warn "LINEAR_API_KEY not set — using the agent's Linear MCP, which must already be authenticated."
    log_warn "Interactive OAuth does not work in headless/--full runs. Set LINEAR_API_KEY for the REST path."
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
