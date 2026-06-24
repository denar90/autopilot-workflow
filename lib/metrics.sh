#!/usr/bin/env bash
# Per-run metrics. Aggregates .autopilot/{state.json,feedback.json,logs/*.log}
# into one JSON line appended to a runs log, with an optional export sink. Turns
# tuning decisions (codex hit-rate, cost per phase, early-exit rate, severity mix)
# from guesswork into measured data. Requires jq; lib/ui.sh for log_warn.

# metrics_enabled — true unless AUTOPILOT_METRICS=off.
metrics_enabled() {
  [[ "${AUTOPILOT_METRICS:-on}" != "off" ]]
}

# metrics_build_record <wt> — print one JSON object summarizing the run. Reads
# state.json + feedback.json + each phase log's final result event. Run-level
# context comes from the environment: TICKET, PROJECT, AUTOPILOT_MODE,
# _AUTOPILOT_REVIEW_DECISION, METRICS_TS. Returns non-zero if state.json is absent.
metrics_build_record() {
  local wt="$1"
  local sf="$wt/.autopilot/state.json" ff="$wt/.autopilot/feedback.json"
  [[ -f "$sf" ]] || return 1
  [[ -f "$ff" ]] || ff=/dev/null

  # Per-phase cost/turns/duration from each log's final result event.
  local per_phase logf name line
  per_phase=$(
    for logf in "$wt"/.autopilot/logs/*.log; do
      [[ -e "$logf" ]] || continue
      name=$(basename "$logf" .log)
      line=$(grep '"type":"result"' "$logf" 2>/dev/null | tail -n1)
      [[ -n "$line" ]] || continue
      printf '%s\n' "$line" | jq -c --arg n "$name" \
        '{($n): {cost: (.total_cost_usd // 0), turns: (.num_turns // 0), duration_ms: (.duration_ms // 0)}}' 2>/dev/null
    done | jq -s 'add // {}' 2>/dev/null
  )
  [[ -n "$per_phase" ]] || per_phase="{}"

  jq -nc \
    --slurpfile s "$sf" \
    --slurpfile f "$ff" \
    --argjson per_phase "$per_phase" \
    --arg ticket "${TICKET:-}" \
    --arg project "${PROJECT:-}" \
    --arg mode "${AUTOPILOT_MODE:-}" \
    --arg action "${_AUTOPILOT_REVIEW_DECISION:-}" \
    --arg ts "${METRICS_TS:-}" '
    ($s[0] // {}) as $st
    | ($f[0] // {}) as $fb
    | {
        ticket: (if $ticket == "" then ($st.ticket // null) else $ticket end),
        project: (if $project == "" then null else $project end),
        mode: (if $mode == "" then null else $mode end),
        final_action: (if $action == "" then null else $action end),
        phase: $st.phase,
        cost_usd: ($st.total_cost_usd // 0),
        cycles: (($fb.cycles // []) | length),
        findings_total: (($fb.items // []) | length),
        findings_by_source: (
          ($fb.items // [])
          | group_by(.source)
          | map({ (.[0].source // "unknown"): (group_by(.status) | map({ (.[0].status // "unknown"): length }) | add) })
          | add // {}
        ),
        per_phase: $per_phase,
        recorded_at: (if $ts == "" then null else $ts end)
      }'
}

# metrics_emit <wt> — append the run record to AUTOPILOT_METRICS_FILE and, when
# AUTOPILOT_METRICS_SINK is set, pipe the record to it (a command, e.g. a curl
# poster to PostHog / Langfuse / a webhook). Best-effort: never fails the run.
metrics_emit() {
  metrics_enabled || return 0
  local wt="$1"
  [[ -n "$wt" && -f "$wt/.autopilot/state.json" ]] || return 0
  local file="${AUTOPILOT_METRICS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/autopilot/runs.jsonl}"
  local rec ts
  ts="$(date -u +%FT%TZ)"
  rec=$(METRICS_TS="$ts" metrics_build_record "$wt" 2>/dev/null) || return 0
  [[ -n "$rec" ]] || return 0
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  printf '%s\n' "$rec" >> "$file" 2>/dev/null || true
  if [[ -n "${AUTOPILOT_METRICS_SINK:-}" ]]; then
    # shellcheck disable=SC2294
    printf '%s\n' "$rec" | eval "$AUTOPILOT_METRICS_SINK" >/dev/null 2>&1 \
      || log_warn "metrics sink failed (AUTOPILOT_METRICS_SINK)"
  fi
  return 0
}
