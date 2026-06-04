#!/usr/bin/env bash
set -euo pipefail

memory="${1:?memory is required}"
cpu="${2:?cpu is required}"
basedir="${3:?basedir is required}"
job_name="${4:?job_name is required}"
cwd="${5:?cwd is required}"
out="${6:?stdout path is required}"
err="${7:?stderr path is required}"
singularitydir="${8:?singularity/apptainer directory is required}"
docker="${9:?docker image name is required}"
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
java_xmx_mb="$(
  awk -v mem="${memory}" '
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

      xmx = int(mem_gb * 0.80 * 1024)
      if (xmx < 256) xmx = 256
      print xmx
    }'
)"
image_dir="${GATKSV_SGE_IMAGE_DIR:-${basedir}/images}"
image="${image_dir}/${docker}"
runner="${GATKSV_SINGULARITY_BIN:-${singularitydir}/singularity}"
gs_dir="${GATKSV_SGE_GS_DIR:-${basedir}/gs}"
melt_bowtie2_wrapper="${GATKSV_SGE_MELT_BOWTIE2_WRAPPER:-${basedir}/sge-test/melt-bowtie2-wrapper/opt-bowtie2}"
java_tool_options="-XX:+UseSerialGC -XX:CICompilerCount=2"
if [[ "${docker}" == "local/melt:2.2.2" ]]; then
  java_tool_options+=" -Xmx${java_xmx_mb}m"
fi

if [[ ! -e "${image}" ]]; then
  echo "container image not found: ${image}" >&2
  exit 2
fi

bind_args=(--bind "${cwd}:${cwd}" --bind "${basedir}/cromwell-executions:/cromwell-executions")
if [[ "${docker}" == "local/melt:2.2.2" && -d "${melt_bowtie2_wrapper}" ]]; then
  bind_args+=(--bind "${melt_bowtie2_wrapper}:/opt/bowtie2")
fi
if [[ -d "${gs_dir}" ]]; then
  bind_args+=(--bind "${gs_dir}:/gs")
fi
for bind_dir in /SSD_ARRAY /ddca2 /ddca3 /ddca4; do
  if [[ -d "${bind_dir}" ]]; then
    bind_args+=(--bind "${bind_dir}:${bind_dir}")
  fi
done
if [[ -n "${GATKSV_SGE_EXTRA_BINDS:-}" ]]; then
  IFS=',' read -r -a extra_binds <<<"${GATKSV_SGE_EXTRA_BINDS}"
  for bind in "${extra_binds[@]}"; do
    [[ -n "${bind}" ]] && bind_args+=(--bind "${bind}")
  done
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
      -v JAVA_TOOL_OPTIONS="${java_tool_options}" \
      "${runner}" exec --no-home "${bind_args[@]}" --pwd "${cwd}" "${image}" bash "${script}"
  )"; then
    echo "${job_id}"
    break
  fi
  sleep "${GATKSV_SGE_QSUB_RETRY_SECONDS:-10}"
done
