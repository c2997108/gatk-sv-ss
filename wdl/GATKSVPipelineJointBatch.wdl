version 1.0

import "MergeBatchSites.wdl" as mergebatchsites
import "GenotypeBatch.wdl" as genotypebatch
import "RegenotypeCNVs.wdl" as regenocnvs
import "MakeCohortVcf.wdl" as makecohortvcf

workflow GATKSVPipelineJointBatch {
  input {
    String cohort_name
    Array[String] batches
    File ped_file

    Array[File] filtered_pesr_vcfs
    Array[File] filtered_depth_vcfs
    Array[File] cutoffs
    Array[File] medianfiles
    Array[File] merged_coverage_files
    Array[File] merged_coverage_file_indexes
    Array[File] merged_disc_files
    Array[File] merged_disc_file_indexes
    Array[File] merged_split_files
    Array[File] merged_split_file_indexes

    File primary_contigs_list
    File primary_contigs_fai
    File allosome_file
    File reference_fasta
    File reference_index
    File reference_dict
    String chr_x
    String chr_y

    File genotype_bin_exclude
    File pesr_exclude_list
    File seed_cutoffs
    String reference_build
    Int genotype_n_RD_genotype_bins
    Int genotype_n_per_split
    Int regeno_n_RdTest_bins
    Int regeno_n_per_split

    File makecohort_bin_exclude
    File clustering_config_part1
    File stratification_config_part1
    File clustering_config_part2
    File stratification_config_part2
    Array[String] track_names
    Array[File] track_bed_files
    File cytobands
    File mei_bed
    File pe_exclude_list
    File HERVK_reference
    File LINE1_reference
    Int max_shard_size_resolve
    Int max_shards_per_chrom_clean_vcf_step1
    Int min_records_per_shard_clean_vcf_step1
    Int clean_vcf1b_records_per_shard
    Int samples_per_clean_vcf_step2_shard
    Int clean_vcf5_records_per_shard
    Float min_sr_background_fail_batches
    Int? random_seed

    Boolean merge_cluster_vcfs = false
    Boolean merge_complex_resolve_vcfs = false
    Boolean merge_complex_genotype_vcfs = false
    Boolean? run_genotypebatch_metrics
    Boolean? run_makecohortvcf_metrics

    String linux_docker
    String gatk_docker
    String sv_base_mini_docker
    String sv_pipeline_docker
    String sv_pipeline_qc_docker
  }

  call mergebatchsites.MergeBatchSites {
    input:
      depth_vcfs = filtered_depth_vcfs,
      pesr_vcfs = filtered_pesr_vcfs,
      cohort = cohort_name,
      sv_pipeline_docker = sv_pipeline_docker
  }

  scatter (i in range(length(batches))) {
    call genotypebatch.GenotypeBatch {
      input:
        batch_pesr_vcf = filtered_pesr_vcfs[i],
        batch_depth_vcf = filtered_depth_vcfs[i],
        cohort_pesr_vcf = MergeBatchSites.cohort_pesr_vcf,
        cohort_depth_vcf = MergeBatchSites.cohort_depth_vcf,
        batch = batches[i],
        rf_cutoffs = cutoffs[i],
        medianfile = medianfiles[i],
        coveragefile = merged_coverage_files[i],
        coveragefile_index = merged_coverage_file_indexes[i],
        discfile = merged_disc_files[i],
        discfile_index = merged_disc_file_indexes[i],
        splitfile = merged_split_files[i],
        splitfile_index = merged_split_file_indexes[i],
        n_RD_genotype_bins = genotype_n_RD_genotype_bins,
        n_per_split = genotype_n_per_split,
        pesr_exclude_list = pesr_exclude_list,
        seed_cutoffs = seed_cutoffs,
        reference_build = reference_build,
        bin_exclude = genotype_bin_exclude,
        ref_dict = reference_dict,
        run_module_metrics = run_genotypebatch_metrics,
        primary_contigs_list = primary_contigs_list,
        sv_base_mini_docker = sv_base_mini_docker,
        sv_pipeline_docker = sv_pipeline_docker,
        linux_docker = linux_docker
    }
  }

  Array[File] trained_depth_depth_sepcutoffs = select_all(GenotypeBatch.trained_genotype_depth_depth_sepcutoff)

  call regenocnvs.RegenotypeCNVs {
    input:
      depth_vcfs = GenotypeBatch.genotyped_depth_vcf,
      cohort_depth_vcf = MergeBatchSites.cohort_depth_vcf,
      batch_depth_vcfs = filtered_depth_vcfs,
      coveragefiles = merged_coverage_files,
      coveragefile_idxs = merged_coverage_file_indexes,
      medianfiles = medianfiles,
      RD_depth_sepcutoffs = trained_depth_depth_sepcutoffs,
      n_per_split = regeno_n_per_split,
      n_RdTest_bins = regeno_n_RdTest_bins,
      batches = batches,
      cohort = cohort_name,
      contig_list = primary_contigs_list,
      regeno_coverage_medians = GenotypeBatch.regeno_coverage_medians,
      sv_base_mini_docker = sv_base_mini_docker,
      sv_pipeline_docker = sv_pipeline_docker
  }

  call makecohortvcf.MakeCohortVcf {
    input:
      cohort_name = cohort_name,
      batches = batches,
      ped_file = ped_file,
      merge_cluster_vcfs = merge_cluster_vcfs,
      merge_complex_resolve_vcfs = merge_complex_resolve_vcfs,
      merge_complex_genotype_vcfs = merge_complex_genotype_vcfs,
      pesr_vcfs = GenotypeBatch.genotyped_pesr_vcf,
      depth_vcfs = RegenotypeCNVs.regenotyped_depth_vcfs,
      disc_files = merged_disc_files,
      bincov_files = merged_coverage_files,
      raw_sr_bothside_pass_files = GenotypeBatch.sr_bothside_pass,
      raw_sr_background_fail_files = GenotypeBatch.sr_background_fail,
      depth_gt_rd_sep_files = trained_depth_depth_sepcutoffs,
      median_coverage_files = medianfiles,
      rf_cutoff_files = cutoffs,
      clustering_config_part1 = clustering_config_part1,
      stratification_config_part1 = stratification_config_part1,
      clustering_config_part2 = clustering_config_part2,
      stratification_config_part2 = stratification_config_part2,
      track_names = track_names,
      track_bed_files = track_bed_files,
      reference_fasta = reference_fasta,
      reference_fasta_fai = reference_index,
      reference_dict = reference_dict,
      bin_exclude = makecohort_bin_exclude,
      contig_list = primary_contigs_fai,
      allosome_fai = allosome_file,
      cytobands = cytobands,
      mei_bed = mei_bed,
      pe_exclude_list = pe_exclude_list,
      HERVK_reference = HERVK_reference,
      LINE1_reference = LINE1_reference,
      max_shard_size_resolve = max_shard_size_resolve,
      max_shards_per_chrom_clean_vcf_step1 = max_shards_per_chrom_clean_vcf_step1,
      min_records_per_shard_clean_vcf_step1 = min_records_per_shard_clean_vcf_step1,
      clean_vcf1b_records_per_shard = clean_vcf1b_records_per_shard,
      samples_per_clean_vcf_step2_shard = samples_per_clean_vcf_step2_shard,
      clean_vcf5_records_per_shard = clean_vcf5_records_per_shard,
      min_sr_background_fail_batches = min_sr_background_fail_batches,
      chr_x = chr_x,
      chr_y = chr_y,
      random_seed = random_seed,
      run_module_metrics = run_makecohortvcf_metrics,
      primary_contigs_list = primary_contigs_list,
      linux_docker = linux_docker,
      gatk_docker = gatk_docker,
      sv_pipeline_docker = sv_pipeline_docker,
      sv_pipeline_qc_docker = sv_pipeline_qc_docker,
      sv_base_mini_docker = sv_base_mini_docker
  }

  output {
    File cohort_pesr_vcf = MergeBatchSites.cohort_pesr_vcf
    File cohort_depth_vcf = MergeBatchSites.cohort_depth_vcf
    Array[File] genotyped_pesr_vcfs = GenotypeBatch.genotyped_pesr_vcf
    Array[File] genotyped_depth_vcfs = GenotypeBatch.genotyped_depth_vcf
    Array[File] regenotyped_depth_vcfs = RegenotypeCNVs.regenotyped_depth_vcfs
    File clean_vcf = MakeCohortVcf.vcf
    File clean_vcf_index = MakeCohortVcf.vcf_index
    File master_vcf_qc = MakeCohortVcf.vcf_qc
    File? metrics_file_makecohortvcf = MakeCohortVcf.metrics_file_makecohortvcf
  }
}
