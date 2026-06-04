#!/usr/bin/env bash
set -euo pipefail

job_id="${1:?job id is required}"

jobcheck="$(qstat -j "${job_id}" 2>&1)" && exit 0
status=$?

if [[ "${status}" == "1" ]] && grep -q "Following jobs do not exist" <<<"${jobcheck}"; then
  sleep "${GATKSV_SGE_COMPLETION_GRACE_SECONDS:-30}"
  exit 1
fi

# Treat transient qstat failures as alive so Cromwell retries the status check.
exit 0
