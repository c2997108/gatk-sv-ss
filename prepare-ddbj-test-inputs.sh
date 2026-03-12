#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source_root="/usr/local/shared_data/public-human-genomes/GRCh38/1000Genomes/CRAM"
sample_list="${repo_root}/samples-ddbj-1000g-hg38-50.txt"
ped_file="${repo_root}/family.ped"
inputs_template="${repo_root}/inputs-template.json"
inputs_file="${repo_root}/inputs.json"
manifest_file="${repo_root}/cram/ddbj_1000g_hg38_50.tsv"
melt_image="${repo_root}/images/local/melt:2.2.2"

mkdir -p "${repo_root}/cram"

if [[ ! -d "${source_root}" ]]; then
  echo "source directory not found: ${source_root}" >&2
  exit 1
fi

if [[ ! -f "${sample_list}" ]]; then
  echo "sample list not found: ${sample_list}" >&2
  exit 1
fi

: > "${ped_file}"
printf "sample_id\tsource_cram\tsource_crai\n" > "${manifest_file}"
sample_index=0

while IFS= read -r sample_id; do
  [[ -n "${sample_id}" ]] || continue

  src_cram="${source_root}/${sample_id}/${sample_id}.cram"
  src_crai="${source_root}/${sample_id}/${sample_id}.cram.crai"

  if [[ ! -r "${src_cram}" || ! -r "${src_crai}" ]]; then
    echo "missing CRAM or CRAI for ${sample_id}" >&2
    exit 1
  fi

  if (( sample_index % 2 == 0 )); then
    sex_code=1
  else
    sex_code=2
  fi

  printf "%s\t%s\t0\t0\t%s\t0\n" "${sample_id}" "${sample_id}" "${sex_code}" >> "${ped_file}"
  printf "%s\t%s\t%s\n" "${sample_id}" "${src_cram}" "${src_crai}" >> "${manifest_file}"
  sample_index=$((sample_index + 1))
done < "${sample_list}"

samples_json="$(jq -Rsc 'split("\n") | map(select(length > 0))' "${sample_list}")"
crams_json="$(awk -v root="${source_root}" 'NF { print root "/" $1 "/" $1 ".cram" }' "${sample_list}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
crais_json="$(awk -v root="${source_root}" 'NF { print root "/" $1 "/" $1 ".cram.crai" }' "${sample_list}" | jq -Rsc 'split("\n") | map(select(length > 0))')"

if [[ -f "${melt_image}" ]]; then
  use_melt_json="true"
else
  use_melt_json="false"
fi

jq \
  --argjson samples "${samples_json}" \
  --argjson crams "${crams_json}" \
  --argjson crais "${crais_json}" \
  --arg use_melt "${use_melt_json}" \
  '.["GATKSVPipelineBatch.samples"] = $samples
   | .["GATKSVPipelineBatch.bam_or_cram_files"] = $crams
   | .["GATKSVPipelineBatch.bam_or_cram_indexes"] = $crais
   | .["GATKSVPipelineBatch.ped_file"] = "family.ped"
   | .["GATKSVPipelineBatch.use_melt"] = $use_melt' \
  "${inputs_template}" > "${inputs_file}"

echo "wrote ${ped_file}"
echo "wrote ${manifest_file}"
echo "wrote ${inputs_file}"
echo "MELT use_melt=${use_melt_json} (${melt_image})"
