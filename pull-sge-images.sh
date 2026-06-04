#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
inputs_json="${1:-${repo_root}/sge-test/inputs.GATKSVPipelineBatch.sge.json}"
image_dir="${GATKSV_SGE_IMAGE_DIR:-${repo_root}/images}"
runner="${GATKSV_SINGULARITY_BIN:-${GATKSV_SINGULARITY_DIR:-/suikou/tool9-all/bin}/singularity}"

if [[ ! -f "${inputs_json}" ]]; then
  echo "Inputs JSON not found: ${inputs_json}" >&2
  exit 1
fi

mkdir -p "${image_dir}"

jq -r '
  to_entries[]
  | select(.key | test("(^|[._])[^.]*docker$|_docker$"))
  | .value
  | strings
' "${inputs_json}" | sort -u | while IFS= read -r image; do
  [[ -n "${image}" ]] || continue
  target="${image_dir}/${image}"
  if [[ -e "${target}" ]]; then
    echo "exists: ${target}"
    continue
  fi
  if [[ "${image}" == local/* ]]; then
    echo "missing local image, not pulling: ${target}" >&2
    continue
  fi
  mkdir -p "$(dirname "${target}")"
  echo "pull: docker://${image} -> ${target}"
  "${runner}" pull --disable-cache --force "${target}" "docker://${image}"
done
