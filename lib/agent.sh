#!/usr/bin/env bash
# Agent invocation wrapper. Requires: $WT, $AUTOPILOT_AGENT_CMD, lib/ui.sh sourced.

# agent_pretty: stream Claude stream-json on stdin → human-readable lines on stdout.
# Non-JSON lines pass through verbatim.
agent_pretty() {
  while IFS= read -r line; do
    case "$line" in
      '{'*)
        printf '%s\n' "$line" | jq -rj \
          --arg cyan "$(printf '\033[36m')" \
          --arg cyan_b "$(printf '\033[1;36m')" \
          --arg green "$(printf '\033[32m')" \
          --arg green_b "$(printf '\033[1;32m')" \
          --arg yellow "$(printf '\033[33m')" \
          --arg dim "$(printf '\033[2m')" \
          --arg reset "$(printf '\033[0m')" '
          def tool_args($i):
            if $i == null or ($i|type) != "object" then ""
            else
              ([$i | to_entries[]
                | "\(.key)=" +
                  (if (.value|type) == "string" then .value
                   elif (.value|type) == "object" then "{…}"
                   elif (.value|type) == "array" then "[…]"
                   else (.value|tostring) end)]
               | join(", "))
            end;
          if .type == "assistant" then
            ( .message.content // [] ) as $c
            | ( [$c[] | select(.type=="text") | .text] | join("") ) as $txt
            | ( [$c[] | select(.type=="tool_use")
                      | "  \($cyan_b)→\($reset) \($cyan)\(.name)\($reset)\($dim)(\(tool_args(.input)))\($reset)\n"]
                | join("") ) as $tools
            | (if $txt != "" then $txt + "\n" else "" end) + $tools
          elif .type == "system" and .subtype == "task_progress" then
            "  \($dim)· \(.description // "")\($reset)\n"
          elif .type == "system" and .subtype == "init" then
            "  \($dim)[session \(.session_id[0:8])] model=\(.model)\($reset)\n"
          elif .type == "result" then
            "\n\($green_b)[done]\($reset) \($green)turns=\(.num_turns // "?") cost=$\(.total_cost_usd // 0) duration_ms=\(.duration_ms // 0)\($reset)\n"
          else empty end
        ' 2>/dev/null || true
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done
}

# render_prompt <prompt_template> <out_file>
# Substitutes {{VAR}} placeholders from current env into a prompt file.
render_prompt() {
  local tmpl="$1" out="$2"
  [[ -f "$tmpl" ]] || { log_err "Template missing: $tmpl"; return 1; }
  sed -E 's/\{\{([A-Z_][A-Z0-9_]*)\}\}/\$\{\1\}/g' "$tmpl" | envsubst > "$out"
}

# run_phase <phase_name>
run_phase() {
  local name="$1"
  local repo_root="${AUTOPILOT_ROOT}"
  local tmpl="${repo_root}/prompts/${name}.md"
  local rendered="${WT}/.autopilot/prompts/${name}.md"
  local logf="${WT}/.autopilot/logs/${name}.log"

  mkdir -p "${WT}/.autopilot/prompts" "${WT}/.autopilot/logs"
  render_prompt "$tmpl" "$rendered" || return 1

  log_info "Phase ${name} → ${AUTOPILOT_AGENT_CMD%% *}"
  set_term_title "${TICKET:-autopilot} · ${name}"
  # Full raw JSON goes to log; terminal sees only filtered human-readable lines.
  # shellcheck disable=SC2086
  ( cd "$WT" && eval $AUTOPILOT_AGENT_CMD ) < "$rendered" 2>&1 \
    | tee "$logf" \
    | agent_pretty
  local rc="${PIPESTATUS[0]}"
  if [[ "$rc" -ne 0 ]]; then
    log_err "Phase ${name} exited ${rc}. Log: ${logf}"
    return "$rc"
  fi
  state_add_cost "$logf"
  log_ok "Phase ${name} done."
}
