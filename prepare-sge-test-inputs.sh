#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
data_root="${GATKSV_TEST_DATA_DIR:-$(cd "${repo_root}/.." && pwd -P)}"
cram_dir="${GATKSV_CRAM_DIR:-${data_root}/cram}"
source_ped="${GATKSV_PED_SOURCE:-${data_root}/cramlist-2023-exec.SRYcov.ped}"
out_dir="${GATKSV_SGE_TEST_DIR:-${repo_root}/sge-test}"
batch_name="${GATKSV_BATCH_NAME:-local_sge_test}"
image_dir="${GATKSV_SGE_IMAGE_DIR:-${repo_root}/images}"

if [[ ! -d "${cram_dir}" ]]; then
  echo "CRAM directory not found: ${cram_dir}" >&2
  exit 1
fi
if [[ ! -f "${source_ped}" ]]; then
  echo "PED file not found: ${source_ped}" >&2
  exit 1
fi

mkdir -p "${out_dir}"
sample_list="${out_dir}/samples.txt"
ped_file="${out_dir}/family.ped"
manifest_file="${out_dir}/cram_manifest.tsv"
values_dir="${out_dir}/values"
build_dir="${out_dir}/build"
batch_inputs="${out_dir}/inputs.GATKSVPipelineBatch.sge.json"
smoke_inputs="${out_dir}/inputs.SGESmokeTest.sge.json"
localize_reads_inputs="${out_dir}/inputs.SGELocalizeReadsTest.sge.json"

find "${cram_dir}" -maxdepth 1 -name '*.cram' -printf '%f\n' \
  | sed 's/\.cram$//' \
  | sort > "${sample_list}.all"

if [[ -n "${GATKSV_TEST_SAMPLE_LIMIT:-}" ]]; then
  sed -n "1,${GATKSV_TEST_SAMPLE_LIMIT}p" "${sample_list}.all" > "${sample_list}"
else
  mv "${sample_list}.all" "${sample_list}"
fi

sample_count="$(wc -l < "${sample_list}")"
if [[ "${sample_count}" -eq 0 ]]; then
  echo "No CRAM files found in ${cram_dir}" >&2
  exit 1
fi

awk 'NR==FNR { samples[$1]=1; next } ($1 in samples) || ($2 in samples)' \
  "${sample_list}" "${source_ped}" > "${ped_file}"

ped_count="$(wc -l < "${ped_file}")"
if [[ "${ped_count}" -ne "${sample_count}" ]]; then
  echo "PED/sample count mismatch: samples=${sample_count}, ped=${ped_count}" >&2
  echo "Missing PED entries:" >&2
  awk 'NR==FNR { ped[$1]=1; ped[$2]=1; next } !($1 in ped)' "${ped_file}" "${sample_list}" >&2
  exit 1
fi

printf "sample_id\tcram\tcrai\n" > "${manifest_file}"
while IFS= read -r sample_id; do
  cram="${cram_dir}/${sample_id}.cram"
  crai="${cram}.crai"
  if [[ ! -e "${cram}" || ! -e "${crai}" ]]; then
    echo "Missing CRAM or CRAI for ${sample_id}" >&2
    exit 1
  fi
  printf "%s\t%s\t%s\n" "${sample_id}" "${cram}" "${crai}" >> "${manifest_file}"
done < "${sample_list}"

samples_json="$(jq -Rsc 'split("\n") | map(select(length > 0))' "${sample_list}")"
crams_json="$(awk -F'\t' 'NR > 1 { print $2 }' "${manifest_file}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
crais_json="$(awk -F'\t' 'NR > 1 { print $3 }' "${manifest_file}" | jq -Rsc 'split("\n") | map(select(length > 0))')"

rm -rf "${values_dir}" "${build_dir}"
mkdir -p "${values_dir}" "${build_dir}"
cp "${repo_root}"/inputs/values/*.json "${values_dir}/"

jq \
  --arg name "${batch_name}" \
  --arg ped "${ped_file}" \
  --argjson samples "${samples_json}" \
  --argjson crams "${crams_json}" \
  '.name = $name
   | .ped_file = $ped
   | .samples = $samples
   | .bam_or_cram_files = $crams' \
  "${repo_root}/inputs/values/ref_panel_1kg.json" > "${values_dir}/local_sge_test.json"

"${repo_root}/scripts/inputs/build_inputs.py" \
  "${values_dir}" \
  "${repo_root}/inputs/templates/test/GATKSVPipelineBatch" \
  "${build_dir}" \
  -a '{ "test_batch": "local_sge_test" }'

if [[ -d "${repo_root}/gs" ]]; then
  default_resource_prefix="${repo_root}/gs"
elif [[ -d "/SSD_ARRAY/gatk-sv/gs" ]]; then
  default_resource_prefix="/SSD_ARRAY/gatk-sv/gs"
else
  default_resource_prefix="${repo_root}/gs"
fi
resource_prefix="${GATKSV_RESOURCE_PREFIX:-${default_resource_prefix}}"
gcnv_model_dir="${resource_prefix}/gatk-sv-resources-public/hg38/v0/sv-resources/ref-panel/1KG/v2/gcnv/model_files"
contig_ploidy_model="${resource_prefix}/gatk-sv-resources-public/hg38/v0/sv-resources/ref-panel/1KG/v2/gcnv/ref_panel_1kg_v2-contig-ploidy-model.tar.gz"
qc_definitions="${resource_prefix}/gatk-sv-ref-panel-1kg/outputs/GATKSVPipelineBatch/38c65ca4-2a07-4805-86b6-214696075fef/ref_panel_1kg.qc_definitions.tsv"

if [[ -d "${gcnv_model_dir}" ]]; then
  gcnv_model_tars_json="$(
    find -L "${gcnv_model_dir}" -maxdepth 1 -name 'ref_panel_1kg_v2-gcnv-model-shard-*.tar.gz' \
      | sort -V \
      | jq -Rsc 'split("\n") | map(select(length > 0))'
  )"
else
  gcnv_model_tars_json="[]"
fi

use_manta="${GATKSV_USE_MANTA:-true}"
use_wham="${GATKSV_USE_WHAM:-true}"
use_melt="${GATKSV_USE_MELT:-false}"
use_scramble="${GATKSV_USE_SCRAMBLE:-true}"
melt_docker="${GATKSV_MELT_DOCKER:-local/melt:2.2.2}"

jq \
  --arg prefix "${resource_prefix}" \
  --arg contig_ploidy_model "${contig_ploidy_model}" \
  --arg qc_definitions "${qc_definitions}" \
  --argjson crais "${crais_json}" \
  --argjson gcnv_model_tars "${gcnv_model_tars_json}" \
  --argjson use_manta "${use_manta}" \
  --argjson use_wham "${use_wham}" \
  --argjson use_melt "${use_melt}" \
  --argjson use_scramble "${use_scramble}" \
  --arg melt_docker "${melt_docker}" \
  '
  def walk(f):
    . as $in
    | if type == "object" then
        reduce keys[] as $key ({}; . + { ($key): ($in[$key] | walk(f)) }) | f
      elif type == "array" then map(walk(f)) | f
      else f
      end;
  def localize_gs:
    if type == "string" and startswith("gs://") then
      $prefix + "/" + (.[5:])
    elif type == "string" and . == "marketplace.gcr.io/google/ubuntu1804" then
      "ubuntu:18.04"
    else
      .
    end;
  walk(localize_gs)
  | .["GATKSVPipelineBatch.bam_or_cram_indexes"] = $crais
  | if ($gcnv_model_tars | length) > 0 then .["GATKSVPipelineBatch.gcnv_model_tars"] = $gcnv_model_tars else . end
  | if ($contig_ploidy_model | length) > 0 then .["GATKSVPipelineBatch.contig_ploidy_model_tar"] = $contig_ploidy_model else . end
  | if ($qc_definitions | length) > 0 then .["GATKSVPipelineBatch.qc_definitions"] = $qc_definitions else . end
  | del(.["GATKSVPipelineBatch.outlier_cutoff_table"])
  | del(.["GATKSVPipelineBatch.GatherSampleEvidenceBatch.reference_bwa_alt"])
  | del(.["GATKSVPipelineBatch.GatherSampleEvidenceBatch.reference_bwa_amb"])
  | del(.["GATKSVPipelineBatch.GatherSampleEvidenceBatch.reference_bwa_ann"])
  | del(.["GATKSVPipelineBatch.GatherSampleEvidenceBatch.reference_bwa_bwt"])
  | del(.["GATKSVPipelineBatch.GatherSampleEvidenceBatch.reference_bwa_pac"])
  | del(.["GATKSVPipelineBatch.GatherSampleEvidenceBatch.reference_bwa_sa"])
  | del(.["GATKSVPipelineBatch.MakeCohortVcf.site_level_comparison_datasets"])
  | .["GATKSVPipelineBatch.use_manta"] = $use_manta
  | .["GATKSVPipelineBatch.use_wham"] = $use_wham
  | .["GATKSVPipelineBatch.use_melt"] = $use_melt
  | .["GATKSVPipelineBatch.use_scramble"] = $use_scramble
  | if $use_melt then .["GATKSVPipelineBatch.melt_docker"] = $melt_docker else . end
  ' \
  "${build_dir}/GATKSVPipelineBatch.json" > "${batch_inputs}"

jq -n \
  --arg ped "${ped_file}" \
  --arg linux_docker "ubuntu:18.04" \
  --argjson crams "${crams_json}" \
  --argjson crais "${crais_json}" \
  '{
    "SGESmokeTest.ped_file": $ped,
    "SGESmokeTest.cram_files": $crams,
    "SGESmokeTest.crai_files": $crais,
    "SGESmokeTest.linux_docker": $linux_docker
  }' > "${smoke_inputs}"

first_cram="$(awk -F'\t' 'NR == 2 { print $2 }' "${manifest_file}")"
first_crai="$(awk -F'\t' 'NR == 2 { print $3 }' "${manifest_file}")"
jq -n \
  --arg reads_path "${first_cram}" \
  --arg reads_index "${first_crai}" \
  '{
    "SGELocalizeReadsTest.reads_path": $reads_path,
    "SGELocalizeReadsTest.reads_index": $reads_index
  }' > "${localize_reads_inputs}"

echo "Wrote ${sample_count} samples"
echo "  ${sample_list}"
echo "  ${ped_file}"
echo "  ${manifest_file}"
echo "  ${batch_inputs}"
echo "  ${smoke_inputs}"
echo "  ${localize_reads_inputs}"
echo "Resource prefix: ${resource_prefix}"
echo "Callers: manta=${use_manta}, wham=${use_wham}, melt=${use_melt}, scramble=${use_scramble}"
