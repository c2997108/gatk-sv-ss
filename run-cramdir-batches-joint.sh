#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
data_root="${GATKSV_DATA_ROOT:-$(cd "${repo_root}/.." && pwd -P)}"

run_root="${GATKSV_RUN_ROOT:-${repo_root}/sge-cramdir-joint}"
if [[ "$run_root" != /* ]]; then
  run_root="${repo_root}/${run_root}"
fi
cohort_name="${GATKSV_COHORT_NAME:-local_sge_joint}"
batch_name_prefix="${GATKSV_BATCH_NAME_PREFIX:-local_sge_}"

sex_region="${GATKSV_SEX_REGION:-chrY:2780855-2797682}"
male_depth_threshold="${GATKSV_MALE_DEPTH_THRESHOLD:-2}"
reference_fasta="${GATKSV_REFERENCE_FASTA:-${repo_root}/gs/gcp-public-data--broad-references/hg38/v0/Homo_sapiens_assembly38.fasta}"

cromwell_jar="${GATKSV_CROMWELL_JAR:-/SSD_ARRAY/gatk-sv_v2024-06-26/cromwell.jar}"
cromwell_config="${GATKSV_CROMWELL_CONFIG:-${repo_root}/cromwell-sge.conf}"
cromwell_options="${GATKSV_CROMWELL_OPTIONS:-${repo_root}/options.sge.json}"
batch_wdl="${GATKSV_BATCH_WDL:-${repo_root}/wdl/GATKSVPipelineBatch.wdl}"
joint_wdl="${GATKSV_JOINT_WDL:-${repo_root}/wdl/GATKSVPipelineJointBatch.wdl}"

manifest="${run_root}/batches.tsv"
metadata_manifest="${run_root}/batch_metadata.tsv"

force="${GATKSV_FORCE:-false}"

usage() {
  cat <<'EOF'
Usage:
  run-cramdir-batches-joint.sh prepare [CRAM_DIR ...]
  run-cramdir-batches-joint.sh run-batches
  run-cramdir-batches-joint.sh prepare-joint
  run-cramdir-batches-joint.sh run-joint
  run-cramdir-batches-joint.sh all [CRAM_DIR ...]

Default CRAM directory discovery:
  If CRAM_DIR is omitted, directories matching cram, cram2, cram3, ...
  under GATKSV_DATA_ROOT are used.

Main environment variables:
  GATKSV_DATA_ROOT              Parent directory containing cram/cram2/... (default: repo parent)
  GATKSV_RUN_ROOT               Output root (default: ./sge-cramdir-joint)
  GATKSV_COHORT_NAME            Joint cohort name (default: local_sge_joint)
  GATKSV_BATCH_NAME_PREFIX      Batch name prefix (default: local_sge_)
  GATKSV_SEX_REGION             Region for sex depth (default: chrY:2780855-2797682)
  GATKSV_MALE_DEPTH_THRESHOLD   mean depth >= threshold is male/PED sex=1 (default: 2)
  GATKSV_REFERENCE_FASTA        Reference FASTA for CRAM depth
  GATKSV_CROMWELL_JAR           Cromwell jar
  GATKSV_CROMWELL_CONFIG        Cromwell config
  GATKSV_CROMWELL_OPTIONS       Cromwell options JSON
  GATKSV_FORCE=true             Recompute/rerun even if outputs already exist

PED convention:
  sample_id sample_id 0 0 sex 0
  sex = 1 if mean_depth >= threshold, otherwise 2.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_file() {
  [[ -s "$1" ]] || die "Missing or empty file: $1"
}

need_dir() {
  [[ -d "$1" ]] || die "Directory not found: $1"
}

sanitize_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.' '_'
}

region_bases() {
  local coords start end
  [[ "$sex_region" == *:* && "$sex_region" == *-* ]] || die "Unsupported region format: $sex_region"
  coords="${sex_region#*:}"
  start="${coords%-*}"
  end="${coords#*-}"
  [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$end" -ge "$start" ]] || die "Unsupported region coordinates: $sex_region"
  echo $((end - start + 1))
}

region_safe_name() {
  printf '%s' "$sex_region" | tr ':,-' '___'
}

discover_cram_dirs() {
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' "$@"
  else
    find "${data_root}" -maxdepth 1 -type d -printf '%p\n' \
      | awk -F/ '($NF ~ /^cram[0-9]*$/) { print }' \
      | sort -V
  fi
}

list_crams() {
  local cram_dir="$1"
  find "${cram_dir}" -maxdepth 1 \( -type f -o -type l \) -name '*.cram' -printf '%p\n' | sort -V
}

compute_depth_table() {
  local cram_dir="$1"
  local out_tsv="$2"
  local bases
  bases="$(region_bases)"

  need_dir "$cram_dir"
  need_file "$reference_fasta"
  need_file "${reference_fasta}.fai"

  if [[ -s "$out_tsv" && "$force" != "true" ]]; then
    log "Keeping existing depth table: $out_tsv"
    return
  fi

  local crams
  crams="$(list_crams "$cram_dir")"
  [[ -n "$crams" ]] || die "No CRAM files found in $cram_dir"

  mkdir -p "$(dirname "$out_tsv")"
  printf 'batch\tsample_id\tcram\tregion\tregion_bases\tmean_depth\tpositions_reported\n' > "$out_tsv"

  while IFS= read -r cram; do
    [[ -n "$cram" ]] || continue
    local sample_id crai batch
    sample_id="$(basename "$cram" .cram)"
    crai="${cram}.crai"
    batch="$(basename "$cram_dir")"
    [[ -e "$cram" ]] || die "Missing CRAM: $cram"
    [[ -e "$crai" ]] || die "Missing CRAI: $crai"

    log "Depth ${batch}/${sample_id}"
    samtools depth --reference "$reference_fasta" -a -r "$sex_region" "$cram" \
      | awk -v batch="$batch" \
            -v sample="$sample_id" \
            -v cram="$cram" \
            -v region="$sex_region" \
            -v expected="$bases" '
          { sum += $3; n++ }
          END {
            if (n == 0) {
              printf "%s\t%s\t%s\t%s\t%d\tNA\t0\n", batch, sample, cram, region, expected
            } else {
              printf "%s\t%s\t%s\t%s\t%d\t%.6f\t%d\n", batch, sample, cram, region, expected, sum / expected, n
            }
          }' >> "$out_tsv"
  done <<< "$crams"
}

write_depth_ped() {
  local depth_tsv="$1"
  local ped="$2"
  need_file "$depth_tsv"
  mkdir -p "$(dirname "$ped")"

  awk -F'\t' -v OFS='\t' -v thr="$male_depth_threshold" '
    NR == 1 { next }
    $6 == "NA" { printf "Missing mean_depth for %s\n", $2 > "/dev/stderr"; exit 2 }
    {
      sex = ($6 + 0 >= thr + 0) ? 1 : 2
      print $2, $2, 0, 0, sex, 0
    }' "$depth_tsv" > "$ped"
}

prepare_one_batch() {
  local cram_dir="$1"
  local base batch_id out_dir depth_tsv sex_ped batch_name
  need_dir "$cram_dir"
  base="$(basename "$cram_dir")"
  batch_id="$(sanitize_id "$base")"
  out_dir="${run_root}/batches/${batch_id}"
  depth_tsv="${out_dir}/$(region_safe_name).mean_depth.tsv"
  sex_ped="${out_dir}/sex_from_$(region_safe_name).ped"
  batch_name="${batch_name_prefix}${batch_id}"

  mkdir -p "$out_dir"
  compute_depth_table "$cram_dir" "$depth_tsv"
  write_depth_ped "$depth_tsv" "$sex_ped"

  log "Preparing GATK-SV inputs for $batch_id"
  (
    export GATKSV_CRAM_DIR="$cram_dir"
    export GATKSV_PED_SOURCE="$sex_ped"
    export GATKSV_SGE_TEST_DIR="$out_dir"
    export GATKSV_BATCH_NAME="$batch_name"
    "${repo_root}/prepare-sge-test-inputs.sh"
  )

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$batch_id" \
    "$cram_dir" \
    "$out_dir" \
    "$batch_name" \
    "${out_dir}/inputs.GATKSVPipelineBatch.sge.json" \
    "${out_dir}/family.ped" \
    "$depth_tsv" >> "$manifest"
}

prepare_batches() {
  mkdir -p "$run_root"
  printf 'batch_id\tcram_dir\tout_dir\tbatch_name\tinputs_json\tped_file\tdepth_tsv\n' > "$manifest"

  local dirs
  dirs="$(discover_cram_dirs "$@")"
  [[ -n "$dirs" ]] || die "No CRAM directories found"

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    prepare_one_batch "$dir"
  done <<< "$dirs"

  local combined_depth first_depth
  combined_depth="${run_root}/all_batches.$(region_safe_name).mean_depth.tsv"
  first_depth="$(tail -n +2 "$manifest" | awk -F'\t' 'NR == 1 { print $7 }')"
  if [[ -n "$first_depth" ]]; then
    head -n 1 "$first_depth" > "$combined_depth"
    tail -n +2 "$manifest" | awk -F'\t' '{ print $7 }' | while IFS= read -r depth_tsv; do
      tail -n +2 "$depth_tsv" >> "$combined_depth"
    done
    log "Wrote combined depth table: $combined_depth"
  fi

  log "Wrote batch manifest: $manifest"
}

recover_metadata_from_log() {
  local log_file="$1"
  local out_json="$2"
  local workflow_name="$3"
  need_file "$log_file"
  python3 - "$log_file" "$out_json" "$workflow_name" <<'PY'
import json
import os
import re
import sys

log_file, out_json, workflow_name = sys.argv[1:4]
text = open(log_file, encoding="utf-8", errors="replace").read()
idx = text.rfind('\n{\n  "outputs"')
if idx < 0:
    raise SystemExit(f"Final outputs JSON not found in {log_file}")
end = text.find("\n[", idx + 1)
blob = text[idx + 1:end if end >= 0 else len(text)]
data = json.loads(blob)
if re.search(r"workflow finished with status 'Succeeded'", text) or re.search(r"completed with status 'Succeeded'", text):
    data["status"] = "Succeeded"
else:
    data.setdefault("status", "Unknown")
data["workflow_name"] = workflow_name
os.makedirs(os.path.dirname(out_json), exist_ok=True)
with open(out_json, "w", encoding="utf-8") as out:
    json.dump(data, out, indent=2, sort_keys=True)
    out.write("\n")
print(out_json)
PY
}

metadata_succeeded() {
  local metadata="$1"
  [[ -s "$metadata" ]] && jq -e '.status == "Succeeded"' "$metadata" >/dev/null 2>&1
}

latest_succeeded_metadata() {
  local out_dir="$1"
  local latest=""
  while IFS= read -r candidate; do
    if metadata_succeeded "$candidate"; then
      latest="$candidate"
    fi
  done < <(find "$out_dir" -maxdepth 1 -type f \( -name 'metadata.GATKSVPipelineBatch.*.recovered.json' -o -name 'metadata.GATKSVPipelineBatch.*.json' \) 2>/dev/null | sort)
  printf '%s\n' "$latest"
}

run_one_batch() {
  local batch_id="$1"
  local out_dir="$2"
  local inputs_json="$3"
  local existing ts log_file metadata rc
  need_file "$inputs_json"
  need_file "$cromwell_jar"
  need_file "$cromwell_config"
  need_file "$cromwell_options"
  need_file "$batch_wdl"

  existing="$(latest_succeeded_metadata "$out_dir")"
  if [[ -n "$existing" && "$force" != "true" ]]; then
    log "Skipping succeeded batch $batch_id: $existing"
    printf '%s\t%s\t%s\t%s\n' "$batch_id" "$out_dir" "$inputs_json" "$existing" >> "$metadata_manifest"
    return
  fi

  ts="$(date +%Y%m%d-%H%M%S)"
  log_file="${out_dir}/run.GATKSVPipelineBatch.${ts}.log"
  metadata="${out_dir}/metadata.GATKSVPipelineBatch.${ts}.recovered.json"

  log "Running GATKSVPipelineBatch for $batch_id"
  set +e
  (
    cd "$repo_root"
    java -Dconfig.file="$cromwell_config" \
      -jar "$cromwell_jar" \
      run "$batch_wdl" \
      --inputs "$inputs_json" \
      --options "$cromwell_options" \
      2>&1 | tee "$log_file"
  )
  rc=$?
  set -e

  recover_metadata_from_log "$log_file" "$metadata" "GATKSVPipelineBatch"
  if ! metadata_succeeded "$metadata"; then
    die "Batch $batch_id did not finish with Succeeded status; see $log_file"
  fi
  if [[ "$rc" -ne 0 ]]; then
    log "Cromwell exited rc=$rc for $batch_id, but workflow status was Succeeded; continuing"
  fi
  printf '%s\t%s\t%s\t%s\n' "$batch_id" "$out_dir" "$inputs_json" "$metadata" >> "$metadata_manifest"
}

run_batches() {
  need_file "$manifest"
  printf 'batch_id\tout_dir\tinputs_json\tmetadata_json\n' > "$metadata_manifest"
  tail -n +2 "$manifest" | while IFS=$'\t' read -r batch_id _cram_dir out_dir _batch_name inputs_json _ped_file _depth_tsv; do
    run_one_batch "$batch_id" "$out_dir" "$inputs_json"
  done
  log "Wrote metadata manifest: $metadata_manifest"
}

write_joint_inputs() {
  need_file "$manifest"
  need_file "$metadata_manifest"

  local joint_dir joint_ped joint_inputs metas_tmp inputs_tmp
  joint_dir="${run_root}/joint"
  joint_ped="${joint_dir}/family.ped"
  joint_inputs="${joint_dir}/inputs.GATKSVPipelineJointBatch.sge.json"
  metas_tmp="${joint_dir}/.batch_metadata_array.json"
  inputs_tmp="${joint_dir}/.batch_inputs_array.json"
  mkdir -p "$joint_dir"

  mapfile -t metadata_files < <(tail -n +2 "$metadata_manifest" | awk -F'\t' '{ print $4 }')
  mapfile -t input_files < <(tail -n +2 "$metadata_manifest" | awk -F'\t' '{ print $3 }')
  mapfile -t ped_files < <(tail -n +2 "$manifest" | awk -F'\t' '{ print $6 }')

  [[ "${#metadata_files[@]}" -gt 0 ]] || die "No batch metadata files listed in $metadata_manifest"
  [[ "${#metadata_files[@]}" -eq "${#input_files[@]}" ]] || die "metadata/input count mismatch"
  [[ "${#metadata_files[@]}" -eq "${#ped_files[@]}" ]] || die "metadata/PED count mismatch"

  local f
  for f in "${metadata_files[@]}" "${input_files[@]}" "${ped_files[@]}"; do
    need_file "$f"
  done

  awk '!seen[$2]++' "${ped_files[@]}" > "$joint_ped"
  jq -s '.' "${metadata_files[@]}" > "$metas_tmp"
  jq -s '.' "${input_files[@]}" > "$inputs_tmp"

  jq -n \
    --slurpfile metas_file "$metas_tmp" \
    --slurpfile inputs_file "$inputs_tmp" \
    --arg cohort_name "$cohort_name" \
    --arg ped "$joint_ped" \
    '
    $metas_file[0] as $metas
    | $inputs_file[0] as $inputs
    | def require($x; $name): if $x == null then error("missing " + $name) else $x end;
      def out($i; $k): require($metas[$i].outputs["GATKSVPipelineBatch." + $k]; "batch " + ($i|tostring) + " output " + $k);
      def inp($k): require($inputs[0]["GATKSVPipelineBatch." + $k]; "input " + $k);
      def subinp($section; $k): require($inputs[0]["GATKSVPipelineBatch." + $section + "." + $k]; "input " + $section + "." + $k);
      def outputs($k): [range(0; $metas|length) as $i | out($i; $k)];
      if (($metas | length) == 0) then error("no batch metadata") else . end
      | if any($metas[]; .status != "Succeeded") then error("one or more batch metadata files are not Succeeded") else . end
      | {
        "GATKSVPipelineJointBatch.cohort_name": $cohort_name,
        "GATKSVPipelineJointBatch.batches": [$inputs[] | require(."GATKSVPipelineBatch.name"; "batch name")],
        "GATKSVPipelineJointBatch.ped_file": $ped,

        "GATKSVPipelineJointBatch.filtered_pesr_vcfs": outputs("filtered_pesr_vcf"),
        "GATKSVPipelineJointBatch.filtered_depth_vcfs": outputs("filtered_depth_vcf"),
        "GATKSVPipelineJointBatch.cutoffs": outputs("cutoffs"),
        "GATKSVPipelineJointBatch.medianfiles": outputs("medianfile"),
        "GATKSVPipelineJointBatch.merged_coverage_files": outputs("merged_coverage_file"),
        "GATKSVPipelineJointBatch.merged_coverage_file_indexes": outputs("merged_coverage_file_index"),
        "GATKSVPipelineJointBatch.merged_disc_files": outputs("merged_disc_file"),
        "GATKSVPipelineJointBatch.merged_disc_file_indexes": outputs("merged_disc_file_index"),
        "GATKSVPipelineJointBatch.merged_split_files": outputs("merged_split_file"),
        "GATKSVPipelineJointBatch.merged_split_file_indexes": outputs("merged_split_file_index"),

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
    ' > "$joint_inputs"

  log "Wrote joint PED: $joint_ped"
  log "Wrote joint inputs: $joint_inputs"
}

run_joint() {
  local joint_dir joint_inputs existing ts log_file metadata rc
  joint_dir="${run_root}/joint"
  joint_inputs="${joint_dir}/inputs.GATKSVPipelineJointBatch.sge.json"
  need_file "$joint_inputs"
  need_file "$cromwell_jar"
  need_file "$cromwell_config"
  need_file "$cromwell_options"
  need_file "$joint_wdl"

  existing="$(find "$joint_dir" -maxdepth 1 -type f -name 'metadata.GATKSVPipelineJointBatch.*.recovered.json' 2>/dev/null | sort | tail -n 1)"
  if [[ -n "$existing" && "$force" != "true" ]] && metadata_succeeded "$existing"; then
    log "Skipping succeeded joint workflow: $existing"
    return
  fi

  ts="$(date +%Y%m%d-%H%M%S)"
  log_file="${joint_dir}/run.GATKSVPipelineJointBatch.${ts}.log"
  metadata="${joint_dir}/metadata.GATKSVPipelineJointBatch.${ts}.recovered.json"

  log "Running GATKSVPipelineJointBatch"
  set +e
  (
    cd "$repo_root"
    java -Dconfig.file="$cromwell_config" \
      -jar "$cromwell_jar" \
      run "$joint_wdl" \
      --inputs "$joint_inputs" \
      --options "$cromwell_options" \
      2>&1 | tee "$log_file"
  )
  rc=$?
  set -e

  recover_metadata_from_log "$log_file" "$metadata" "GATKSVPipelineJointBatch"
  if ! metadata_succeeded "$metadata"; then
    die "Joint workflow did not finish with Succeeded status; see $log_file"
  fi
  if [[ "$rc" -ne 0 ]]; then
    log "Cromwell exited rc=$rc for joint workflow, but workflow status was Succeeded; continuing"
  fi
  log "Joint metadata: $metadata"
  jq -r '.outputs["GATKSVPipelineJointBatch.clean_vcf"] // empty' "$metadata"
}

cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

case "$cmd" in
  prepare)
    prepare_batches "$@"
    ;;
  run-batches)
    run_batches
    ;;
  prepare-joint)
    write_joint_inputs
    ;;
  run-joint)
    run_joint
    ;;
  all)
    prepare_batches "$@"
    run_batches
    write_joint_inputs
    run_joint
    ;;
  *)
    usage >&2
    die "Unknown command: $cmd"
    ;;
esac
