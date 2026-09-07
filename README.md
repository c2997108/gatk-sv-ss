# GATK-SV-SS

[Japanese README](README_jp.md)

GATK-SV-SS is a fork of [Broad GATK-SV](https://github.com/broadinstitute/gatk-sv)
adapted for user-level execution on an on-premises SGE cluster with
Singularity/Apptainer. This `main` branch is based on GATK-SV `v1.1`.

The main additions in this branch are:

- a Cromwell `ConfigBackend` for SGE
- qsub wrappers for Singularity and non-container tasks
- local resource path handling for mirrored `gs://` resources
- CRAM-directory based batch execution
- automatic PED sex assignment from mean depth over `chrY:2780855-2797682`
- multi-batch joint calling from completed batch outputs
- SCRAMble-enabled mobile element calling by default, with MELT disabled

For implementation details, see [SGE_PORT_SUMMARY.md](SGE_PORT_SUMMARY.md).
This guide updates the [v2024-06-26 Japanese guide](https://github.com/c2997108/gatk-sv-ss/blob/v2024-06-26/README_jp.md)
for this branch; old image bundles and MELT setup are not prerequisites for the default workflow.

## Requirements

The pipeline was developed for a shared-storage Linux SGE cluster.

Required on the Cromwell host:

- Java 11 or later
- PostgreSQL for persistent Cromwell metadata and call caching
- `jq`
- `samtools`
- `bcftools`, `bgzip`, and `tabix`
- Python 3 with Jinja2 (used to generate input JSON)
- Git

Required on all SGE worker nodes:

- SGE execution daemon
- Singularity or Apptainer
- access to the shared repository, CRAM files, resource mirror, and image mirror

The submission host also needs `qsub`, `qstat`, and `qdel`. The wrappers request
the `smp` parallel environment and `mem_req` resource; adapt both submission
scripts to your site's SGE configuration. Shared files must be visible at the
same absolute paths on every worker.

Recommended infrastructure:

- all-SSD shared storage
- enough temporary and output space for the sample count
- high shared-storage bandwidth

Large GATK-SV runs are I/O intensive. A 100-sample run can require many TB of
working space, and a large joint call can require a high-memory node.

## Repository Layout

Important local additions:

- `cromwell-sge.conf`: Cromwell SGE backend configuration
- `submit-singularity-job.sh`: qsub wrapper for containerized WDL tasks
- `submit-nonsingularity-job.sh`: qsub wrapper for non-container WDL tasks
- `check-alive.sh`: Cromwell job liveness check through `qstat`
- `options.sge.json`: Cromwell options for call caching and local outputs
- `prepare-sge-test-inputs.sh`: creates local `GATKSVPipelineBatch` inputs
- `run-cramdir-batches-joint.sh`: end-to-end CRAM-directory batch and joint runner
- `pull-sge-images.sh`: pulls Docker images into a local Singularity image mirror
- `wdl/GATKSVPipelineJointBatch.wdl`: wrapper for merging batch outputs and making
  a final cohort VCF

Run outputs are intentionally ignored by Git:

- `cromwell-executions/`
- `cromwell-outputs/`
- `cromwell-workflow-logs/`
- `sge-cramdir-joint/`
- `sge-test*/`
- local `gs` and `images` mirrors

## Clone

Use the `main` branch.

```bash
git clone https://github.com/c2997108/gatk-sv-ss.git
cd gatk-sv-ss
git switch main
```

Run subsequent commands from the repository root. For a new installation:

1. Install the required commands, Cromwell jar, and PostgreSQL.
2. Configure the container executable, shared-path binds, and SGE resources.
3. Prepare the hg38 resource mirror, CRAM/CRAI files, and depth reference.
4. Generate inputs with `prepare`, then acquire images with `pull-sge-images.sh`.
5. Check the smoke tests, then use `all` to run batches and joint calling.

## Cromwell

The old guide provides a [patched Cromwell release](https://github.com/c2997108/cromwell/releases/tag/92ky)
for Singularity call caching and stable timestamps on WDL-generated files.
To install that jar outside the repository:

```bash
mkdir -p ../tools
curl -fL -o ../tools/cromwell.jar \
  https://github.com/c2997108/cromwell/releases/download/92ky/cromwell-92-ee3e2b0-SNAP.jar
export GATKSV_CROMWELL_JAR="$(cd ../tools && pwd)/cromwell.jar"
```

Without an override, the wrapper uses this installation-specific path:

```text
/SSD_ARRAY/gatk-sv_v2024-06-26/cromwell.jar
```

For another location, set:

```bash
export GATKSV_CROMWELL_JAR=/path/to/cromwell.jar
```

The Cromwell command used by the wrapper has this form:

```bash
java -Dconfig.file=/path/to/gatk-sv-ss/cromwell-sge.conf \
  -jar /path/to/cromwell.jar \
  run /path/to/gatk-sv-ss/wdl/GATKSVPipelineBatch.wdl \
  --inputs /path/to/run-root/batches/cram/inputs.GATKSVPipelineBatch.sge.json \
  --options /path/to/gatk-sv-ss/options.sge.json
```

The joint workflow is run similarly with `wdl/GATKSVPipelineJointBatch.wdl`.

## PostgreSQL For Call Caching

`cromwell-sge.conf` is configured to use PostgreSQL at
`localhost:5432/cromwell`. Persistent metadata is important: rerunning the same
workflow can reuse completed calls and successful batches.

One local Docker example:

```bash
docker volume create cromwell-pgdata

docker run -d --name cromwell-postgres \
  -e POSTGRES_PASSWORD=cromwellpw \
  -e POSTGRES_USER=cromwell \
  -e POSTGRES_DB=cromwell \
  -v cromwell-pgdata:/var/lib/postgresql/data \
  -p 127.0.0.1:5432:5432 \
  postgres:15
```

Stop it when needed:

```bash
docker stop cromwell-postgres
```

Reuse it with `docker start cromwell-postgres`. The example credentials match
`cromwell-sge.conf`; change both together for your installation. Docker is only
needed for this database example, not on workers.

## Singularity/Apptainer Images

The SGE backend executes Docker images through Singularity/Apptainer. Images are
resolved under:

```text
${GATKSV_SGE_IMAGE_DIR:-./images}
```

After preparing an inputs JSON, pull the needed images:

```bash
export GATKSV_SINGULARITY_BIN="$(command -v singularity)"
./pull-sge-images.sh sge-cramdir-joint/batches/cram/inputs.GATKSVPipelineBatch.sge.json
```

For an executable named `apptainer`, replace `command -v singularity` with
`command -v apptainer`. Without this override the default executable is
`/suikou/tool9-all/bin/singularity`.

Repeat for another inputs JSON if it uses additional images. The wrapper expects
the local image path to mirror the Docker image name, for example:

```text
images/us.gcr.io/broad-dsde-methods/gatk-sv/sv-pipeline:2025-09-02-v1.0.5-631368eb
```

This branch uses SCRAMble by default and does not require a MELT image for the
standard run. If you explicitly enable MELT, you must provide a local MELT image
and handle the MELT license requirements separately.

## Local Resource Mirror

GATK-SV input templates contain many `gs://` resource paths. This fork maps
those paths to a local mirror:

```text
gs://bucket/path/to/file
```

becomes:

```text
${GATKSV_RESOURCE_PREFIX}/bucket/path/to/file
```

By default, `GATKSV_RESOURCE_PREFIX` is `./gs` if that directory exists. You can
override it:

```bash
export GATKSV_RESOURCE_PREFIX=/path/to/local/gs-mirror
```

The mirror must include the GATK-SV public resources used by the generated
inputs, including reference FASTA/index/dict, 1KG reference-panel resources,
gCNV model tarballs, masks, bin files, and clustering/QC resources.
The wrapper does not download these files. Use the paths in
`inputs/values/resources_hg38.json` and `inputs/values/ref_panel_1kg.json`, together
with the overrides in `prepare-sge-test-inputs.sh`, to populate the mirror.
An old resource/image archive alone is not a verified v1.1 installation.

## CRAM Directory Layout

The top-level wrapper expects one or more directories named:

```text
cram
cram2
cram3
...
```

By default, these directories are discovered under the parent directory of the
repository. For example:

```text
/analysis/gatk-sv-ss
/analysis/cram
/analysis/cram2
/analysis/cram3
```

Each CRAM directory must contain one `.cram` and one `.cram.crai` per sample:

```text
cram/
  SAMPLE001.cram
  SAMPLE001.cram.crai
  SAMPLE002.cram
  SAMPLE002.cram.crai
```

Sample IDs are taken from the CRAM basename, for example `SAMPLE001` from
`SAMPLE001.cram`.
Use globally unique sample IDs across all batches, matching the CRAM read-group
`SM` values. Avoid whitespace in sample IDs and directory paths. These templates
use hg38 resources; CRAMs and the decoding reference must be compatible with them.

For the `/analysis` layout above, expose that shared path inside containers:

```bash
export GATKSV_SGE_EXTRA_BINDS=/analysis:/analysis
```

If the CRAM directories are elsewhere, set:

```bash
export GATKSV_DATA_ROOT=/path/to/parent-containing-cram-dirs
```

or pass directories explicitly:

```bash
./run-cramdir-batches-joint.sh all /path/to/cram /path/to/cram2
```

## PED And Sex Assignment

The multi-batch wrapper creates a PED file for each batch. It calculates mean
depth over:

```text
chrY:2780855-2797682
```

using `samtools depth`, then assigns:

- mean depth `>= 2`: male, PED sex `1`
- mean depth `< 2`: female, PED sex `2`

The generated PED format is:

```text
sample_id  sample_id  0  0  sex  0
```

The columns are family ID, individual ID, father ID, mother ID, sex, and phenotype.
This creates unrelated individuals; it does not preserve a biological pedigree.
The sex field is a depth-based assignment, not an independently verified label.

You can override the region or threshold:

```bash
export GATKSV_SEX_REGION=chrY:2780855-2797682
export GATKSV_MALE_DEPTH_THRESHOLD=2
```

The CRAM depth calculation needs a local reference FASTA and `.fai`:

```bash
export GATKSV_REFERENCE_FASTA=/path/to/Homo_sapiens_assembly38.fasta
```

Set this explicitly when using an external resource mirror: the depth reference
default is separately fixed under the repository's `gs/` directory.

## Prepare Only

To create batch manifests, depth tables, PED files, and Cromwell inputs without
running Cromwell:

If Jinja2 is missing, first run `python3 -m pip install Jinja2` in your active
Python environment.

```bash
export GATKSV_USE_MELT=false
export GATKSV_USE_SCRAMBLE=true

./run-cramdir-batches-joint.sh prepare
```

Outputs:

```text
sge-cramdir-joint/batches.tsv
sge-cramdir-joint/all_batches.chrY_2780855_2797682.mean_depth.tsv
sge-cramdir-joint/batches/<batch>/family.ped
sge-cramdir-joint/batches/<batch>/inputs.GATKSVPipelineBatch.sge.json
```

## Run All Batches And Joint Calling

For a new installation, prepare inputs, acquire the required resources and images,
and run the smoke tests below before starting the full workflow. Install Jinja2
in your active Python environment with `python3 -m pip install Jinja2` if needed.
The normal end-to-end command is:

```bash
cd /path/to/gatk-sv-ss

export GATKSV_USE_MELT=false
export GATKSV_USE_SCRAMBLE=true

./run-cramdir-batches-joint.sh all
```

This performs:

1. discover CRAM directories
2. compute chrY depth
3. write per-batch PED files
4. write per-batch `GATKSVPipelineBatch` input JSON files
5. run `GATKSVPipelineBatch.wdl` for each batch
6. collect successful batch metadata
7. build `GATKSVPipelineJointBatch` input JSON
8. run joint calling

Batches run sequentially; tasks within the active workflow run in parallel.
The joint wrapper runs `MergeBatchSites`, `GenotypeBatch` for each batch,
`RegenotypeCNVs`, and `MakeCohortVcf`.
It reads these ten outputs from each batch's successful metadata:

- `filtered_pesr_vcf`, `filtered_depth_vcf`
- `cutoffs`, `medianfile`
- `merged_coverage_file`, `merged_coverage_file_index`
- `merged_disc_file`, `merged_disc_file_index`
- `merged_split_file`, `merged_split_file_index`

Their paths are written directly into the joint input JSON; no manual copy to a
merge directory is required. Keep those files available. Shared resources come
from the first batch's inputs, so use consistent resources and settings across batches.

## Stepwise Execution

For manual control:

```bash
./run-cramdir-batches-joint.sh prepare
./run-cramdir-batches-joint.sh run-batches
./run-cramdir-batches-joint.sh prepare-joint
./run-cramdir-batches-joint.sh run-joint
```

## Resuming A Failed Run

Rerun the same command:

```bash
./run-cramdir-batches-joint.sh all
```

The wrapper skips batches with succeeded recovered metadata unless
`GATKSV_FORCE=true` is set. Cromwell call caching also reuses completed calls
when the PostgreSQL database and execution outputs are still available.

Force regeneration and rerun:

```bash
export GATKSV_FORCE=true
./run-cramdir-batches-joint.sh all
```

This regenerates the depth tables and bypasses the wrapper's success-based skip;
Cromwell call caching remains enabled. It does not force every task to recompute.
Unset `GATKSV_FORCE` afterwards. Success-based skipping does not compare changed
inputs: use a new `GATKSV_RUN_ROOT` when changing samples or analysis settings.

## Useful Runtime Controls

Set concurrency in `cromwell-sge.conf`:

```hocon
concurrent-job-limit = 100
```

This is the backend job limit for a Cromwell process, not a guarantee of 100
running jobs. SGE scheduling and storage capacity also limit throughput.

Exclude problematic SGE hosts:

```bash
export GATKSV_SGE_HOST_EXCLUDES=analysis004,analysis017
```

Add extra Singularity binds:

```bash
export GATKSV_SGE_EXTRA_BINDS=/path1:/path1,/path2:/container/path2
```

Set Singularity/Apptainer:

```bash
export GATKSV_SINGULARITY_DIR=/path/to/bin
export GATKSV_SINGULARITY_BIN=/path/to/singularity
```

Set a custom output root:

```bash
export GATKSV_RUN_ROOT=/path/to/sge-cramdir-joint
```

## Outputs

Main run directory:

```text
sge-cramdir-joint/
```

Important files:

```text
sge-cramdir-joint/batches.tsv
sge-cramdir-joint/batch_metadata.tsv
sge-cramdir-joint/all_batches.chrY_2780855_2797682.mean_depth.tsv
sge-cramdir-joint/batches/<batch>/metadata.GATKSVPipelineBatch.*.recovered.json
sge-cramdir-joint/joint/inputs.GATKSVPipelineJointBatch.sge.json
sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json
```

Each batch and joint directory also contains timestamped Cromwell logs. Recovered
metadata contains the status and outputs reconstructed from those logs, not full
task metadata. Task working files are in `cromwell-executions/`, and final-output
exports use `cromwell-outputs/` according to `options.sge.json`.
`GATKSV_RUN_ROOT` moves the wrapper files, not these Cromwell directories.
If multiple recovered JSON files exist, select the intended successful run;
the wildcard examples below print results from every matching file.

Get the final cleaned VCF:

```bash
jq -r '.outputs["GATKSVPipelineJointBatch.clean_vcf"]' \
  sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json
```

Get the final VCF index:

```bash
jq -r '.outputs["GATKSVPipelineJointBatch.clean_vcf_index"]' \
  sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json
```

Other useful joint outputs:

```bash
jq -r '.outputs["GATKSVPipelineJointBatch.cohort_depth_vcf"]' \
  sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json

jq -r '.outputs["GATKSVPipelineJointBatch.cohort_pesr_vcf"]' \
  sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json

jq -r '.outputs["GATKSVPipelineJointBatch.master_vcf_qc"]' \
  sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json
```

## Optional Monitoring

This repository includes helper scripts used during the completed local run:

```bash
./codex-gatksv-monitor-check.sh sge-cramdir-joint/codex-monitor/snapshot.latest.md
./codex-gatksv-monitor-loop.sh start-screen
```

These are optional operational helpers. They are not required by GATK-SV itself.
The check script records status; `start-screen` starts an autonomous Codex loop
that can edit scripts and restart workflows. Review its prompt and configuration
before enabling it; it uses `--dangerously-bypass-approvals-and-sandbox`.

## Smoke Tests

After generating inputs, basic local checks can be run through Cromwell:

```bash
java -Dconfig.file=cromwell-sge.conf \
  -jar "$GATKSV_CROMWELL_JAR" \
  run wdl/SGESmokeTest.wdl \
  --inputs sge-cramdir-joint/batches/cram/inputs.SGESmokeTest.sge.json \
  --options options.sge.json
```

Localization test:

```bash
java -Dconfig.file=cromwell-sge.conf \
  -jar "$GATKSV_CROMWELL_JAR" \
  run wdl/SGELocalizeReadsTest.wdl \
  --inputs sge-cramdir-joint/batches/cram/inputs.SGELocalizeReadsTest.sge.json \
  --options options.sge.json
```

## Notes

- The default caller set is Manta, WHAM, and SCRAMble.
- MELT is disabled by default in this branch.
- Repeated runs are expected; successful jobs are reused by Cromwell call caching.
- Avoid deleting `cromwell-executions/` or the PostgreSQL database if you want
  call caching to remain effective.
- Corrupted intermediate gzip files were observed during the local run. Investigate
  the failing task and storage logs, quarantine confirmed corrupt outputs, and
  check cache reuse before restarting; high load alone does not establish the cause.
