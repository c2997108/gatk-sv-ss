#!/usr/bin/env bash
set -euo pipefail

memory_gb="$1"
cpu="$2"
basedir="$3"
job_name="$4"
cwd="$5"
out="$6"
err="$7"
singularitydir="$8"
docker="$9"
script="${10}"

if [[ -z "${memory_gb}" || "${memory_gb}" == "null" ]]; then
  memory_gb="4.0"
fi

mem_mb="$(awk -v gb="${memory_gb}" '
  BEGIN {
    m = (gb + 0) * 1024
    printf "%d", (m == int(m) ? m : int(m) + 1)
  }'
)"
dockerimagedir="${basedir}/images"
wrapper_dir="${basedir}/.slurm-wrappers"
mkdir -p "${wrapper_dir}"
wrapper="$(mktemp "${wrapper_dir}/${job_name}.XXXXXX.sh")"

cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

engine="\$(command -v apptainer || command -v singularity || true)"
if [[ -z "\${engine}" ]]; then
  echo "apptainer/singularity command not found" >&2
  exit 1
fi

exec "\${engine}" exec --no-home \
  --bind "${cwd}:${cwd}" \
  --bind "${basedir}/gs:/gs" \
  --bind "${basedir}/cromwell-executions:/cromwell-executions" \
  --pwd "${cwd}" \
  "${dockerimagedir}/${docker}" \
  bash "${script}"
EOF
chmod 700 "${wrapper}"

sbatch_args=(
  --parsable
  --job-name="${job_name}"
  --chdir="${cwd}"
  --output="${out}"
  --error="${err}"
  --ntasks=1
  --cpus-per-task="${cpu}"
  --mem="${mem_mb}M"
  --export=ALL,JAVA_TOOL_OPTIONS=-XX:+UseSerialGC\ -XX:CICompilerCount=2
)

if [[ -n "${SLURM_PARTITION:-}" ]]; then
  sbatch_args+=(--partition="${SLURM_PARTITION}")
fi
if [[ -n "${SLURM_ACCOUNT:-}" ]]; then
  sbatch_args+=(--account="${SLURM_ACCOUNT}")
fi
if [[ -n "${SLURM_QOS:-}" ]]; then
  sbatch_args+=(--qos="${SLURM_QOS}")
fi
if [[ -n "${SLURM_TIME_LIMIT:-}" ]]; then
  sbatch_args+=(--time="${SLURM_TIME_LIMIT}")
fi

while true; do
  job_id="$(sbatch "${sbatch_args[@]}" "${wrapper}")"
  status=$?

  if [[ ${status} -eq 0 ]]; then
    echo "${job_id%%;*}"
    break
  fi

  sleep 10
done
