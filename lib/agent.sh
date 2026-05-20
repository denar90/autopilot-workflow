#!/usr/bin/env bash
# Agent invocation wrapper. Requires: $WT, $AUTOPILOT_AGENT_CMD, lib/ui.sh sourced.

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
  # shellcheck disable=SC2086
  ( cd "$WT" && eval $AUTOPILOT_AGENT_CMD ) < "$rendered" 2>&1 | tee "$logf"
  local rc="${PIPESTATUS[0]}"
  if [[ "$rc" -ne 0 ]]; then
    log_err "Phase ${name} exited ${rc}. Log: ${logf}"
    return "$rc"
  fi
  log_ok "Phase ${name} done."
}
