#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
run_root="${GATKSV_RUN_ROOT:-${repo_root}/sge-cramdir-joint}"
out="${1:-}"

latest_file() {
  local pattern="$1"
  find "$run_root" -type f -path "$pattern" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk 'NR == 1 { $1=""; sub(/^ /, ""); print }'
}

print_metadata_status() {
  local label="$1"
  local pattern="$2"
  local any=false

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    any=true
    if command -v jq >/dev/null 2>&1; then
      status="$(jq -r '.status // "UNKNOWN"' "$f" 2>/dev/null || printf 'UNREADABLE')"
      clean_vcf="$(jq -r '.outputs["GATKSVPipelineJointBatch.clean_vcf"] // empty' "$f" 2>/dev/null || true)"
    else
      status="jq-not-found"
      clean_vcf=""
    fi
    printf -- '- %s: `%s` status=`%s`\n' "$label" "$f" "$status"
    if [[ -n "$clean_vcf" ]]; then
      printf '  clean_vcf: `%s`\n' "$clean_vcf"
    fi
  done < <(find "$run_root" -type f -path "$pattern" 2>/dev/null | sort)

  if [[ "$any" == false ]]; then
    printf -- '- %s: none found\n' "$label"
  fi
}

render() {
  local latest_overall latest_batch latest_joint
  latest_overall="$(latest_file "${run_root}/run-all.*.screen.log")"
  latest_batch="$(latest_file "${run_root}/batches/*/run.GATKSVPipelineBatch.*.log")"
  latest_joint="$(latest_file "${run_root}/joint/run.GATKSVPipelineJointBatch.*.log")"

  printf '# GATK-SV Codex Monitor Snapshot\n\n'
  printf -- '- time: `%s`\n' "$(date '+%F %T %Z')"
  printf -- '- repo: `%s`\n' "$repo_root"
  printf -- '- run_root: `%s`\n' "$run_root"
  printf -- '- latest_overall_log: `%s`\n' "${latest_overall:-none}"
  printf -- '- latest_batch_log: `%s`\n' "${latest_batch:-none}"
  printf -- '- latest_joint_log: `%s`\n\n' "${latest_joint:-none}"

  printf '## Processes\n\n```text\n'
  screen -ls 2>&1 || true
  printf '\n'
  qstat -u "${USER}" 2>&1 || true
  printf '\n'
  pgrep -af 'run-cramdir-batches-joint|cromwell.jar|GATKSVPipeline|submit-singularity-job' 2>/dev/null | cut -c 1-320 || true
  printf '```\n\n'

  printf '## Run Manifests\n\n```text\n'
  if [[ -s "${run_root}/batches.tsv" ]]; then
    wc -l "${run_root}/batches.tsv"
    sed -n '1,20p' "${run_root}/batches.tsv"
  else
    printf 'No batches.tsv\n'
  fi
  printf '\n'
  if [[ -s "${run_root}/batch_metadata.tsv" ]]; then
    wc -l "${run_root}/batch_metadata.tsv"
    cat "${run_root}/batch_metadata.tsv"
  else
    printf 'No batch_metadata.tsv\n'
  fi
  printf '```\n\n'

  printf '## Metadata\n\n'
  print_metadata_status 'batch' "${run_root}/batches/*/metadata.GATKSVPipelineBatch.*.recovered.json"
  print_metadata_status 'joint' "${run_root}/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json"
  printf '\n'

  printf '## Recent Failure Markers\n\n```text\n'
  for f in "$latest_overall" "$latest_batch" "$latest_joint"; do
    [[ -n "${f:-}" && -s "$f" ]] || continue
    printf -- '--- %s ---\n' "$f"
    grep -E "transitioned to state Failed|workflow finished with status 'Failed'|exited with return code|invalid compressed data|No such file or directory|Traceback|ERROR" "$f" \
      | tail -n 40 | cut -c 1-320 || true
  done
  printf '```\n\n'

  printf '## Recent Success And Progress Markers\n\n```text\n'
  for f in "$latest_overall" "$latest_batch" "$latest_joint"; do
    [[ -n "${f:-}" && -s "$f" ]] || continue
    printf -- '--- %s ---\n' "$f"
    grep -E "Succeeded|CallCached|Starting |Submitted|Running subworkflow|transitioned to state|workflow finished with status" "$f" \
      | tail -n 40 | cut -c 1-320 || true
  done
  printf '```\n\n'

  printf '## Latest Overall Log Tail\n\n```text\n'
  if [[ -n "${latest_overall:-}" && -s "$latest_overall" ]]; then
    tail -n 80 "$latest_overall" | cut -c 1-320
  else
    printf 'No overall log found.\n'
  fi
  printf '```\n'
}

if [[ -n "$out" ]]; then
  mkdir -p "$(dirname "$out")"
  tmp="${out}.tmp.$$"
  render > "$tmp"
  mv "$tmp" "$out"
else
  render
fi
