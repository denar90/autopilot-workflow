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
