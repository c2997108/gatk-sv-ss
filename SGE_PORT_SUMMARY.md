# GATK-SV v1.1 SGE/on-prem port summary

This repository is based on Broad GATK-SV `v1.1` and adds local SGE execution
support for CRAM-directory batch runs followed by multi-batch joint calling.

## Base

- Upstream base: `broadinstitute/gatk-sv` tag `v1.1`
- Local branch: `sge-port-v1.1`
- Main committed port: `0c99d9e6 Add SGE support for local GATK-SV runs`
- Final successful run included a few additional working-tree adjustments:
  - `cromwell-sge.conf`: `concurrent-job-limit = 100`
  - `prepare-sge-test-inputs.sh`: default `GATKSV_USE_MELT=false`, `GATKSV_USE_SCRAMBLE=true`
  - `submit-singularity-job.sh` and `submit-nonsingularity-job.sh`: optional host exclusion with `GATKSV_SGE_HOST_EXCLUDES`
  - `wdl/GatherBatchEvidenceMetrics.wdl`: `BAFMetrics` default memory 30G -> 60G

## Cromwell/SGE execution layer

Added a Cromwell ConfigBackend configuration:

- `cromwell-sge.conf`
  - Backend name: `SGE`
  - Execution root: `cromwell-executions`
  - Enables call caching and file-hash cache.
  - Uses PostgreSQL at `localhost:5432/cromwell` so cache and metadata survive
    across `cromwell run` invocations.
  - Disables Docker hash lookup because execution is through local
    Singularity/Apptainer images.
  - Converts WDL runtime attributes into `qsub` submissions.
  - Uses `check-alive.sh` for Cromwell job liveness checks.
  - Current concurrency limit is `100`.

Added qsub wrappers:

- `submit-singularity-job.sh`
  - Runs WDL tasks with a Singularity/Apptainer image.
  - Resolves image names under `${GATKSV_SGE_IMAGE_DIR:-./images}`.
  - Binds:
    - task cwd
    - `cromwell-executions` as `/cromwell-executions`
    - local mirrored Google resources under `/gs` when available
    - `/SSD_ARRAY`, `/ddca2`, `/ddca3`, `/ddca4` when present
    - extra binds from `GATKSV_SGE_EXTRA_BINDS`
  - Converts Cromwell memory to SGE `mem_req` per core.
  - Adds conservative Java defaults through `JAVA_TOOL_OPTIONS`.
  - Retries `qsub` submission on transient failure.
  - Supports host exclusion via `GATKSV_SGE_HOST_EXCLUDES`.

- `submit-nonsingularity-job.sh`
  - Same SGE submission model for non-container tasks.
  - Also supports `GATKSV_SGE_HOST_EXCLUDES`.

- `check-alive.sh`
  - Wraps `qstat -j`.
  - Treats transient `qstat` failures as alive.
  - Returns not-alive only after a short completion grace period when SGE says
    the job no longer exists.

- `options.sge.json`
  - Enables call-cache read/write.
  - Writes final outputs under `cromwell-outputs` using relative output paths.

## Input generation and CRAM-directory workflow

Added scripts to generate local inputs and run the pipeline:

- `prepare-sge-test-inputs.sh`
  - Reads CRAM files from a local CRAM directory.
  - Builds `samples.txt`, `family.ped`, and `cram_manifest.tsv`.
  - Converts GATK-SV resource paths from `gs://...` to local `/gs/...` paths.
  - Adds `.crai` paths as `GATKSVPipelineBatch.bam_or_cram_indexes`.
  - Points gCNV model inputs to locally mirrored resource files.
  - Removes inputs that assume unavailable BWA sidecar files or external
    comparison datasets.
  - Selects callers; the current default is Manta + WHAM + SCRAMble, with MELT
    disabled.

- `run-cramdir-batches-joint.sh`
  - Discovers directories named `cram`, `cram2`, `cram3`, ... under
    `GATKSV_DATA_ROOT`.
  - Computes mean depth over `chrY:2780855-2797682` for each CRAM.
  - Creates PED sex from that depth:
    - mean depth `>= 2`: male, PED sex `1`
    - mean depth `< 2`: female, PED sex `2`
  - Runs `GATKSVPipelineBatch.wdl` once per CRAM directory.
  - Reuses successful batch metadata and skips already-succeeded batches unless
    `GATKSV_FORCE=true`.
  - Recovers final Cromwell output JSON from logs into
    `metadata.GATKSVPipelineBatch.*.recovered.json`.
  - Builds joint inputs from all succeeded batch metadata.
  - Runs `GATKSVPipelineJointBatch.wdl`.

- `prepare-sge-joint-inputs.sh`
  - Earlier two-batch helper for constructing joint inputs from batch metadata.
  - Superseded for general use by `run-cramdir-batches-joint.sh prepare-joint`.

- `pull-sge-images.sh`
  - Reads Docker image names from an inputs JSON and pulls them into
    `./images` as Singularity images.

- `debug-singularity-job.sh`
  - Prints the Singularity command that would be submitted for a Cromwell task.

## WDL changes

Added local test WDLs:

- `wdl/SGESmokeTest.wdl`
  - Verifies PED, CRAM, and CRAI presence under the SGE backend.

- `wdl/SGELocalizeReadsTest.wdl`
  - Exercises `GatherSampleEvidence.LocalizeReads` against local CRAM/CRAI
    inputs.

Added joint wrapper WDL:

- `wdl/GATKSVPipelineJointBatch.wdl`
  - Runs the joint-calling stages normally used after per-batch output:
    - `MergeBatchSites`
    - `GenotypeBatch`
    - `RegenotypeCNVs`
    - `MakeCohortVcf`
  - Takes per-batch filtered VCFs, cutoffs, median coverage files, and PE/SR/RD
    evidence files from each `GATKSVPipelineBatch` metadata output.
  - Produces the final cleaned cohort VCF and QC tarball.

Modified upstream WDL tasks for on-prem execution:

- `wdl/GatherSampleEvidence.wdl`
  - Marks CRAM and CRAI inputs as optional-localization candidates.
  - Changes `LocalizeReads` from forced copy to hard-link, then symlink, then
    copy fallback. This reduces shared-storage load.
  - Marks the read index as localization-optional for aligner checks.

- `wdl/GermlineCNVCase.wdl`, `wdl/GermlineCNVCohort.wdl`,
  `wdl/GermlineCNVTasks.wdl`
  - Sets task-local `HOME`, `XDG_CACHE_HOME`, `PYTENSOR_FLAGS`, and
    `THEANO_FLAGS` so GATK/gCNV Python components do not write into unavailable
    or shared home/cache locations.
  - Replaces parallel in-place `gunzip` on localized read-count files with
    `zcat > uncompressed file`, avoiding destructive mutation of cached inputs.

- `wdl/MakeBincovMatrix.wdl`
  - Replaces FIFO fan-out in `ZPaste` with materialized decompressed columns to
    avoid hangs on the shared filesystem.

- `wdl/CombineBatches.wdl` and `wdl/TasksClusterBatch.wdl`
  - Adds `tabix -f` before GATK clustering steps that require current VCF
    indexes.

- `wdl/Utils.wdl`, `wdl/Vapor.wdl`, `wdl/Whamg.wdl`
  - Makes `gcloud auth application-default print-access-token` optional.
    Local runs do not require GCS OAuth when files are already localized.

- `wdl/Whamg.wdl`
  - Removes intermediate BAM/BAI files after VCF generation to reduce disk use.

- `wdl/MELT.wdl`
  - Increases retry counts and memory headroom.
  - Adds missing VCF header definitions needed by downstream processing.
  - Removes large intermediate files.
  - In the final successful run MELT was disabled and SCRAMble was used instead.

- `wdl/GatherBatchEvidenceMetrics.wdl`
  - Raises `BAFMetrics` default memory to 60G after an observed 30G/rc137 kill.

Input template changes:

- `inputs/templates/test/GATKSVPipelineBatch/GATKSVPipelineBatch*.json.tmpl`
  - Adds `gcnv_gatk_docker`.
  - Fixes `MakeCohortVcf.stratification_config_part1` to use the stratification
    config instead of the clustering config.

- `inputs/values/dockers.json`
  - Adds `gcnv_gatk_docker` for gCNV tasks.

## Final execution command shape

The top-level run was:

```bash
cd /SSD_ARRAY/gatk-sv-1.1/gatk-sv
export GATKSV_USE_MELT=false
export GATKSV_USE_SCRAMBLE=true
./run-cramdir-batches-joint.sh all
```

Internally, each batch used:

```bash
java -Dconfig.file=/SSD_ARRAY/gatk-sv-1.1/gatk-sv/cromwell-sge.conf \
  -jar /SSD_ARRAY/gatk-sv_v2024-06-26/cromwell.jar \
  run /SSD_ARRAY/gatk-sv-1.1/gatk-sv/wdl/GATKSVPipelineBatch.wdl \
  --inputs /SSD_ARRAY/gatk-sv-1.1/gatk-sv/sge-cramdir-joint/batches/<batch>/inputs.GATKSVPipelineBatch.sge.json \
  --options /SSD_ARRAY/gatk-sv-1.1/gatk-sv/options.sge.json
```

The joint workflow used:

```bash
java -Dconfig.file=/SSD_ARRAY/gatk-sv-1.1/gatk-sv/cromwell-sge.conf \
  -jar /SSD_ARRAY/gatk-sv_v2024-06-26/cromwell.jar \
  run /SSD_ARRAY/gatk-sv-1.1/gatk-sv/wdl/GATKSVPipelineJointBatch.wdl \
  --inputs /SSD_ARRAY/gatk-sv-1.1/gatk-sv/sge-cramdir-joint/joint/inputs.GATKSVPipelineJointBatch.sge.json \
  --options /SSD_ARRAY/gatk-sv-1.1/gatk-sv/options.sge.json
```

## Completed run

The final run completed successfully:

- Batch `cram`: `Succeeded`
- Batch `cram2`: `Succeeded`
- Batch `cram3`: `Succeeded`
- Joint workflow: `Succeeded`
- Overall log ended with `rc=0` at `2026-07-14 02:01:01 JST`

Key records:

- Batch manifest:
  `sge-cramdir-joint/batch_metadata.tsv`
- Joint metadata:
  `sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.20260713-151216.recovered.json`
- Completion marker:
  `sge-cramdir-joint/codex-monitor/COMPLETE`
- Final cleaned VCF:
  `cromwell-executions/GATKSVPipelineJointBatch/df3cf09e-0a71-4300-a46a-70023ab5cbcb/call-MakeCohortVcf/MakeCohortVcf/829fe3ee-196f-4688-9b9e-264bf64fbd41/call-CleanVcf/CleanVcf/8806c502-f3fd-428c-b983-68173c5b43a0/call-ConcatCleanedVcfs/execution/local_sge_joint.cleaned.vcf.gz`
- Final VCF index:
  same path with `.tbi`
- Merged depth VCF:
  `cromwell-executions/GATKSVPipelineJointBatch/df3cf09e-0a71-4300-a46a-70023ab5cbcb/call-MergeBatchSites/MergeBatchSites/5fb823ae-08c3-47ea-93c6-7b10f297eb0c/call-MergeDepthVcfs/execution/local_sge_joint.all_batches.depth.vcf.gz`
- Merged PESR VCF:
  `cromwell-executions/GATKSVPipelineJointBatch/df3cf09e-0a71-4300-a46a-70023ab5cbcb/call-MergeBatchSites/MergeBatchSites/5fb823ae-08c3-47ea-93c6-7b10f297eb0c/call-MergePESRVcfs/execution/local_sge_joint.all_batches.pesr.vcf.gz`

## Operational notes

- Successful jobs are reused through Cromwell call caching backed by PostgreSQL.
- The pipeline is sensitive to shared-storage load. The main mitigations are:
  - link-before-copy CRAM localization
  - persistent call caching
  - controlled `concurrent-job-limit`
  - materialized bincov matrix columns instead of FIFO fan-out
  - avoiding destructive input decompression
- If a host is suspected of producing bad outputs, exclude it with:

```bash
export GATKSV_SGE_HOST_EXCLUDES=analysis004
```

- The monitor helpers are not part of upstream GATK-SV, but were added locally
  for this run:
  - `codex-gatksv-monitor-check.sh`
  - `codex-gatksv-monitor-loop.sh`
  - `codex-gatksv-monitor.prompt.md`
