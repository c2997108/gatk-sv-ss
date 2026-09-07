#!/usr/bin/env bash
set -euo pipefail

memory="${1:?memory is required}"
cpu="${2:?cpu is required}"
basedir="${3:?basedir is required}"
job_name="${4:?job_name is required}"
cwd="${5:?cwd is required}"
out="${6:?stdout path is required}"
err="${7:?stderr path is required}"
_singularitydir="${8:-}"
_docker="${9:-}"
script="${10:?script is required}"

mem_per_core="$(
  awk -v mem="${memory}" -v cpu="${cpu}" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    BEGIN {
      mem = trim(mem)
      value = mem
      sub(/[[:space:]]*[[:alpha:]]+$/, "", value)
      unit = toupper(mem)
      sub(/^[0-9.]+[[:space:]]*/, "", unit)
      sub(/IB$/, "B", unit)

      if (unit == "" || unit == "G" || unit == "GB") {
        mem_gb = value
      } else if (unit == "M" || unit == "MB") {
        mem_gb = value / 1024
      } else if (unit == "K" || unit == "KB") {
        mem_gb = value / 1048576
      } else if (unit == "B") {
        mem_gb = value / 1073741824
      } else {
        mem_gb = value
      }

      if (cpu < 1) cpu = 1
      if (mem_gb <= 0) mem_gb = 4
      printf "%.3fG", mem_gb / cpu
    }'
)"

qsub_resource_args=()
if [[ -n "${GATKSV_SGE_HOST_EXCLUDES:-}" ]]; then
  host_expr=""
  IFS=',' read -r -a excluded_hosts <<<"${GATKSV_SGE_HOST_EXCLUDES}"
  for host in "${excluded_hosts[@]}"; do
    host="${host//[[:space:]]/}"
    [[ -z "${host}" ]] && continue
    [[ -n "${host_expr}" ]] && host_expr+="&"
    host_expr+="!${host}"
  done
  if [[ -n "${host_expr}" ]]; then
    qsub_resource_args+=(-l "h=${host_expr}")
  fi
fi

while true; do
  if job_id="$(
    qsub \
      -terse \
      -V \
      -b y \
      -N "${job_name}" \
      -wd "${cwd}" \
      -o "${out}" \
      -e "${err}" \
      -pe smp "${cpu}" \
      -l mem_req="${mem_per_core}" \
      "${qsub_resource_args[@]}" \
      -v JAVA_TOOL_OPTIONS="-XX:+UseSerialGC -XX:CICompilerCount=2" \
      /usr/bin/env bash "${script}"
  )"; then
    echo "${job_id}"
    break
  fi
  sleep "${GATKSV_SGE_QSUB_RETRY_SECONDS:-10}"
done
