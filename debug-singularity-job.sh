#!/usr/bin/env bash
set -euo pipefail

memory_gb="${1:?memory_gb is required}"
cpu="${2:?cpu is required}"
basedir="${3:?basedir is required}"
job_name="${4:?job_name is required}"
cwd="${5:?cwd is required}"
out="${6:?stdout path is required}"
err="${7:?stderr path is required}"
singularitydir="${8:?singularity/apptainer directory is required}"
docker="${9:?docker image name is required}"
script="${10:?script is required}"

image_dir="${GATKSV_SGE_IMAGE_DIR:-${basedir}/images}"
runner="${GATKSV_SINGULARITY_BIN:-${singularitydir}/singularity}"
gs_dir="${GATKSV_SGE_GS_DIR:-${basedir}/gs}"

bind_args=(--bind "${cwd}:${cwd}" --bind "${basedir}/cromwell-executions:/cromwell-executions")
if [[ -d "${gs_dir}" ]]; then
  bind_args+=(--bind "${gs_dir}:/gs")
fi
for bind_dir in /SSD_ARRAY /ddca2 /ddca3 /ddca4; do
  if [[ -d "${bind_dir}" ]]; then
    bind_args+=(--bind "${bind_dir}:${bind_dir}")
  fi
done

printf '%q ' "${runner}" exec --no-home "${bind_args[@]}" --pwd "${cwd}" "${image_dir}/${docker}" bash "${script}"
printf '\n'
