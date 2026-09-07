#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
run_root="${GATKSV_RUN_ROOT:-${repo_root}/sge-cramdir-joint}"
monitor_dir="${GATKSV_CODEX_MONITOR_DIR:-${run_root}/codex-monitor}"
prompt="${CODEX_GATKSV_MONITOR_PROMPT:-${repo_root}/codex-gatksv-monitor.prompt.md}"
interval="${CODEX_GATKSV_MONITOR_INTERVAL:-600}"
max_iterations="${CODEX_GATKSV_MONITOR_MAX_ITERATIONS:-0}"
codex_bin="${CODEX_BIN:-codex}"
session="${CODEX_GATKSV_MONITOR_SCREEN:-gatksv_codex_monitor}"

status_md="${monitor_dir}/status.md"
loop_log="${monitor_dir}/loop.log"
lock_dir="${monitor_dir}/loop.lock"
complete_marker="${monitor_dir}/COMPLETE"
blocked_marker="${monitor_dir}/BLOCKED"
stop_marker="${monitor_dir}/STOP"

usage() {
  cat <<'EOF'
Usage:
  codex-gatksv-monitor-loop.sh once
  codex-gatksv-monitor-loop.sh loop
  codex-gatksv-monitor-loop.sh start-screen
  codex-gatksv-monitor-loop.sh stop
  codex-gatksv-monitor-loop.sh status

Environment:
  CODEX_GATKSV_MONITOR_INTERVAL=600
  CODEX_GATKSV_MONITOR_MAX_ITERATIONS=0
  CODEX_GATKSV_MONITOR_EXTRA_ARGS='--model gpt-5'
  GATKSV_RUN_ROOT=/path/to/sge-cramdir-joint

The loop stops when sge-cramdir-joint/codex-monitor/COMPLETE exists.
Create sge-cramdir-joint/codex-monitor/STOP or run the stop command to stop it.
EOF
}

append_status() {
  mkdir -p "$monitor_dir"
  printf '%s\n' "$*" >> "$status_md"
}

run_once() {
  mkdir -p "${monitor_dir}/iterations"
  [[ -s "$prompt" ]] || {
    printf 'Missing prompt: %s\n' "$prompt" >&2
    return 2
  }

  local ts iter_dir jsonl last_msg snapshot rc
  ts="$(date '+%Y%m%d-%H%M%S')"
  iter_dir="${monitor_dir}/iterations/${ts}"
  jsonl="${iter_dir}/codex-events.jsonl"
  last_msg="${iter_dir}/last-message.md"
  snapshot="${iter_dir}/snapshot.md"
  mkdir -p "$iter_dir"

  "${repo_root}/codex-gatksv-monitor-check.sh" "$snapshot" || true

  append_status ""
  append_status "## Iteration ${ts}"
  append_status ""
  append_status "- snapshot: \`${snapshot}\`"
  append_status "- events: \`${jsonl}\`"
  append_status "- last_message: \`${last_msg}\`"

  local extra_args=()
  if [[ -n "${CODEX_GATKSV_MONITOR_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    extra_args=(${CODEX_GATKSV_MONITOR_EXTRA_ARGS})
  fi

  set +e
  "$codex_bin" exec \
    --cd "$repo_root" \
    --dangerously-bypass-approvals-and-sandbox \
    --output-last-message "$last_msg" \
    --json \
    "${extra_args[@]}" \
    - < "$prompt" > "$jsonl" 2>&1
  rc=$?
  set -e

  append_status "- codex_rc: \`${rc}\`"
  if [[ -s "$last_msg" ]]; then
    append_status ""
    append_status "### Codex Summary"
    append_status ""
    sed -n '1,160p' "$last_msg" >> "$status_md"
    append_status ""
  fi
  return "$rc"
}

start_loop() {
  mkdir -p "$monitor_dir"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    printf 'Monitor loop already appears to be running: %s\n' "$lock_dir" >&2
    return 1
  fi
  trap 'rm -rf "$lock_dir"' EXIT

  {
    printf '# GATK-SV Codex Monitor\n\n'
    printf -- '- started: `%s`\n' "$(date '+%F %T %Z')"
    printf -- '- repo: `%s`\n' "$repo_root"
    printf -- '- run_root: `%s`\n' "$run_root"
    printf -- '- interval_seconds: `%s`\n' "$interval"
    printf -- '- prompt: `%s`\n' "$prompt"
    printf '\n'
  } >> "$status_md"

  local i=0 rc=0
  while true; do
    if [[ -e "$stop_marker" ]]; then
      append_status ""
      append_status "## Stopped"
      append_status ""
      append_status "- time: \`$(date '+%F %T %Z')\`"
      append_status "- reason: STOP marker exists"
      return 0
    fi
    if [[ -e "$complete_marker" ]]; then
      append_status ""
      append_status "## Complete Marker Seen"
      append_status ""
      append_status "- time: \`$(date '+%F %T %Z')\`"
      return 0
    fi

    i=$((i + 1))
    run_once || rc=$?

    if [[ -e "$complete_marker" || -e "$blocked_marker" ]]; then
      return 0
    fi
    if [[ "$max_iterations" != "0" && "$i" -ge "$max_iterations" ]]; then
      append_status ""
      append_status "## Max Iterations Reached"
      append_status ""
      append_status "- time: \`$(date '+%F %T %Z')\`"
      append_status "- max_iterations: \`${max_iterations}\`"
      return "$rc"
    fi

    sleep "$interval"
  done
}

start_screen() {
  mkdir -p "$monitor_dir"
  rm -f "$stop_marker"
  screen -dmS "$session" bash -lc "cd '$repo_root' && exec ./codex-gatksv-monitor-loop.sh loop >> '$loop_log' 2>&1"
  printf 'Started screen session: %s\n' "$session"
  printf 'Status: %s\n' "$status_md"
  printf 'Loop log: %s\n' "$loop_log"
}

cmd="${1:-loop}"
case "$cmd" in
  once)
    run_once
    ;;
  loop)
    start_loop
    ;;
  start-screen)
    start_screen
    ;;
  stop)
    mkdir -p "$monitor_dir"
    printf 'stop requested at %s\n' "$(date '+%F %T %Z')" > "$stop_marker"
    printf 'Wrote %s\n' "$stop_marker"
    ;;
  status)
    "${repo_root}/codex-gatksv-monitor-check.sh" "${monitor_dir}/snapshot.latest.md"
    printf 'Snapshot: %s\n' "${monitor_dir}/snapshot.latest.md"
    printf 'Status: %s\n' "$status_md"
    screen -ls || true
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
