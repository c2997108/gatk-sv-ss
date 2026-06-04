#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

batch1_metadata="${1:-${GATKSV_BATCH1_METADATA:-${repo_root}/sge-test/metadata.GATKSVPipelineBatch.idxfixcache.20260531-011737.json}}"
batch2_metadata="${2:-${GATKSV_BATCH2_METADATA:-}}"
out_dir="${3:-${GATKSV_JOINT_TEST_DIR:-${repo_root}/sge-test-joint}}"

batch1_inputs="${GATKSV_BATCH1_INPUTS:-${repo_root}/sge-test/inputs.GATKSVPipelineBatch.sge.json}"
batch2_inputs="${GATKSV_BATCH2_INPUTS:-${repo_root}/sge-test-cram2/inputs.GATKSVPipelineBatch.sge.json}"
batch1_ped="${GATKSV_BATCH1_PED:-${repo_root}/sge-test/family.ped}"
batch2_ped="${GATKSV_BATCH2_PED:-${repo_root}/sge-test-cram2/family.ped}"
cohort_name="${GATKSV_JOINT_COHORT_NAME:-local_sge_joint}"

if [[ -z "${batch2_metadata}" ]]; then
  batch2_metadata="$(find "${repo_root}/sge-test-cram2" -maxdepth 1 -type f -name 'metadata.GATKSVPipelineBatch.*.json' -size +0c | sort | tail -n 1)"
fi

for path in "${batch1_metadata}" "${batch2_metadata}" "${batch1_inputs}" "${batch2_inputs}" "${batch1_ped}" "${batch2_ped}"; do
  if [[ ! -s "${path}" ]]; then
    echo "Required file missing or empty: ${path}" >&2
    exit 1
  fi
done

mkdir -p "${out_dir}"
joint_ped="${out_dir}/family.ped"
joint_inputs="${out_dir}/inputs.GATKSVPipelineJointBatch.sge.json"

awk '!seen[$2]++' "${batch1_ped}" "${batch2_ped}" > "${joint_ped}"

batch1_name="$(jq -r '."GATKSVPipelineBatch.name"' "${batch1_inputs}")"
batch2_name="$(jq -r '."GATKSVPipelineBatch.name"' "${batch2_inputs}")"

jq -n \
  --slurpfile m1 "${batch1_metadata}" \
  --slurpfile m2 "${batch2_metadata}" \
  --slurpfile inp "${batch1_inputs}" \
  --arg cohort_name "${cohort_name}" \
  --arg batch1_name "${batch1_name}" \
  --arg batch2_name "${batch2_name}" \
  --arg ped "${joint_ped}" \
  '
  def require($x; $name): if $x == null then error("missing " + $name) else $x end;
  def out1($k): require($m1[0].outputs["GATKSVPipelineBatch." + $k]; "batch1 output " + $k);
  def out2($k): require($m2[0].outputs["GATKSVPipelineBatch." + $k]; "batch2 output " + $k);
  def inp($k): require($inp[0]["GATKSVPipelineBatch." + $k]; "input " + $k);
  def subinp($section; $k): require($inp[0]["GATKSVPipelineBatch." + $section + "." + $k]; "input " + $section + "." + $k);

  if $m1[0].status != "Succeeded" then error("batch1 metadata status is " + ($m1[0].status // "null")) else . end
  | if $m2[0].status != "Succeeded" then error("batch2 metadata status is " + ($m2[0].status // "null")) else . end
  | {
    "GATKSVPipelineJointBatch.cohort_name": $cohort_name,
    "GATKSVPipelineJointBatch.batches": [$batch1_name, $batch2_name],
    "GATKSVPipelineJointBatch.ped_file": $ped,

    "GATKSVPipelineJointBatch.filtered_pesr_vcfs": [out1("filtered_pesr_vcf"), out2("filtered_pesr_vcf")],
    "GATKSVPipelineJointBatch.filtered_depth_vcfs": [out1("filtered_depth_vcf"), out2("filtered_depth_vcf")],
    "GATKSVPipelineJointBatch.cutoffs": [out1("cutoffs"), out2("cutoffs")],
    "GATKSVPipelineJointBatch.medianfiles": [out1("medianfile"), out2("medianfile")],
    "GATKSVPipelineJointBatch.merged_coverage_files": [out1("merged_coverage_file"), out2("merged_coverage_file")],
    "GATKSVPipelineJointBatch.merged_coverage_file_indexes": [out1("merged_coverage_file_index"), out2("merged_coverage_file_index")],
    "GATKSVPipelineJointBatch.merged_disc_files": [out1("merged_disc_file"), out2("merged_disc_file")],
    "GATKSVPipelineJointBatch.merged_disc_file_indexes": [out1("merged_disc_file_index"), out2("merged_disc_file_index")],
    "GATKSVPipelineJointBatch.merged_split_files": [out1("merged_split_file"), out2("merged_split_file")],
    "GATKSVPipelineJointBatch.merged_split_file_indexes": [out1("merged_split_file_index"), out2("merged_split_file_index")],

    "GATKSVPipelineJointBatch.primary_contigs_list": inp("primary_contigs_list"),
    "GATKSVPipelineJointBatch.primary_contigs_fai": inp("primary_contigs_fai"),
    "GATKSVPipelineJointBatch.allosome_file": inp("allosome_file"),
    "GATKSVPipelineJointBatch.reference_fasta": inp("reference_fasta"),
    "GATKSVPipelineJointBatch.reference_index": inp("reference_index"),
    "GATKSVPipelineJointBatch.reference_dict": inp("reference_dict"),
    "GATKSVPipelineJointBatch.chr_x": inp("chr_x"),
    "GATKSVPipelineJointBatch.chr_y": inp("chr_y"),

    "GATKSVPipelineJointBatch.genotype_bin_exclude": subinp("GenotypeBatch"; "bin_exclude"),
    "GATKSVPipelineJointBatch.pesr_exclude_list": subinp("GenotypeBatch"; "pesr_exclude_list"),
    "GATKSVPipelineJointBatch.seed_cutoffs": subinp("GenotypeBatch"; "seed_cutoffs"),
    "GATKSVPipelineJointBatch.reference_build": subinp("GenotypeBatch"; "reference_build"),
    "GATKSVPipelineJointBatch.genotype_n_RD_genotype_bins": subinp("GenotypeBatch"; "n_RD_genotype_bins"),
    "GATKSVPipelineJointBatch.genotype_n_per_split": subinp("GenotypeBatch"; "n_per_split"),
    "GATKSVPipelineJointBatch.regeno_n_RdTest_bins": subinp("RegenotypeCNVs"; "n_RdTest_bins"),
    "GATKSVPipelineJointBatch.regeno_n_per_split": subinp("RegenotypeCNVs"; "n_per_split"),

    "GATKSVPipelineJointBatch.makecohort_bin_exclude": subinp("MakeCohortVcf"; "bin_exclude"),
    "GATKSVPipelineJointBatch.clustering_config_part1": subinp("MakeCohortVcf"; "clustering_config_part1"),
    "GATKSVPipelineJointBatch.stratification_config_part1": subinp("MakeCohortVcf"; "stratification_config_part1"),
    "GATKSVPipelineJointBatch.clustering_config_part2": subinp("MakeCohortVcf"; "clustering_config_part2"),
    "GATKSVPipelineJointBatch.stratification_config_part2": subinp("MakeCohortVcf"; "stratification_config_part2"),
    "GATKSVPipelineJointBatch.track_names": subinp("MakeCohortVcf"; "track_names"),
    "GATKSVPipelineJointBatch.track_bed_files": subinp("MakeCohortVcf"; "track_bed_files"),
    "GATKSVPipelineJointBatch.cytobands": subinp("MakeCohortVcf"; "cytobands"),
    "GATKSVPipelineJointBatch.mei_bed": subinp("MakeCohortVcf"; "mei_bed"),
    "GATKSVPipelineJointBatch.pe_exclude_list": subinp("MakeCohortVcf"; "pe_exclude_list"),
    "GATKSVPipelineJointBatch.HERVK_reference": subinp("MakeCohortVcf"; "HERVK_reference"),
    "GATKSVPipelineJointBatch.LINE1_reference": subinp("MakeCohortVcf"; "LINE1_reference"),
    "GATKSVPipelineJointBatch.max_shard_size_resolve": subinp("MakeCohortVcf"; "max_shard_size_resolve"),
    "GATKSVPipelineJointBatch.max_shards_per_chrom_clean_vcf_step1": subinp("MakeCohortVcf"; "max_shards_per_chrom_clean_vcf_step1"),
    "GATKSVPipelineJointBatch.min_records_per_shard_clean_vcf_step1": subinp("MakeCohortVcf"; "min_records_per_shard_clean_vcf_step1"),
    "GATKSVPipelineJointBatch.clean_vcf1b_records_per_shard": subinp("MakeCohortVcf"; "clean_vcf1b_records_per_shard"),
    "GATKSVPipelineJointBatch.samples_per_clean_vcf_step2_shard": subinp("MakeCohortVcf"; "samples_per_clean_vcf_step2_shard"),
    "GATKSVPipelineJointBatch.clean_vcf5_records_per_shard": subinp("MakeCohortVcf"; "clean_vcf5_records_per_shard"),
    "GATKSVPipelineJointBatch.min_sr_background_fail_batches": subinp("MakeCohortVcf"; "min_sr_background_fail_batches"),
    "GATKSVPipelineJointBatch.random_seed": subinp("MakeCohortVcf"; "random_seed"),

    "GATKSVPipelineJointBatch.linux_docker": inp("linux_docker"),
    "GATKSVPipelineJointBatch.gatk_docker": inp("gatk_docker"),
    "GATKSVPipelineJointBatch.sv_base_mini_docker": inp("sv_base_mini_docker"),
    "GATKSVPipelineJointBatch.sv_pipeline_docker": inp("sv_pipeline_docker"),
    "GATKSVPipelineJointBatch.sv_pipeline_qc_docker": inp("sv_pipeline_qc_docker")
  }
  ' > "${joint_inputs}"

ped_count="$(wc -l < "${joint_ped}")"
batch_count="$(jq -r '."GATKSVPipelineJointBatch.batches" | length' "${joint_inputs}")"

echo "Wrote joint inputs for ${batch_count} batches and ${ped_count} PED records"
echo "  ${joint_ped}"
echo "  ${joint_inputs}"
echo "  batch1 metadata: ${batch1_metadata}"
echo "  batch2 metadata: ${batch2_metadata}"
