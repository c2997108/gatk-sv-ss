#!/usr/bin/env bash
set -euo pipefail

job_id="$1"

if squeue -h -j "${job_id}" -o "%i" | grep -q .; then
  exit 0
fi

sleep 30
exit 1
