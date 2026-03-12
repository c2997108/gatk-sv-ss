# DDBJ / SLURM quick start

This manual describes the procedure for running GATK-SV-SS using 50 CRAM files on the DDBJ supercomputer. Use the SLURM backend in `cromwell-slurm.conf`.

## 1. Download runtime files

```bash
git clone https://github.com/c2997108/gatk-sv-ss.git
cd gatk-sv-ss

export GATKSV_SS_ROOT="$PWD"

wget -c -O gatk-sv-singularity.tar.gz 'https://zenodo.org/records/17994642/files/gatk-sv-singularity.tar.gz?download=1'
tar xf gatk-sv-singularity.tar.gz

wget -c -O cromwell.jar https://github.com/c2997108/cromwell/releases/download/92ky/cromwell-92-97d07e0-SNAP.jar
```

## 2. enable MELT on DDBJ

Download `MELTv2.2.2.tar.gz` from https://melt.igs.umaryland.edu/downloads.php. Place `MELTv2.2.2.tar.gz` at the repository top level or under `melt/`, then run the helper script:

```bash
./build-melt-image-ddbj.sh --melt-tar MELTv2.2.2.tar.gz
```

The script downloads GATK 4.2.6.1 if needed, builds a temporary sandbox from `docker://c2997108/gatk-sv:melt-pre`, adds MELT, and writes `images/local/melt:2.2.2`.

## 3. Prepare the 50-sample 1000 Genomes test batch

The sample list is fixed in `samples-ddbj-1000g-hg38-50.txt`.
`prepare-ddbj-test-inputs.sh` creates:

- `family.ped` with alternating male / female sex labels for GATK-SV validation.
- `cram/ddbj_1000g_hg38_50.tsv` with direct source CRAM/CRAI paths from the DDBJ shared mirror.
- `inputs.json` from `inputs-template.json`.

```bash
./prepare-ddbj-test-inputs.sh
```

If you analyze your own CRAM files, please correctly specify the sex of each individual in the fifth column of `family.ped` (1 = male; 2 = female; other = unknown), list the sample IDs in `"GATKSVPipelineBatch.samples"`, provide the absolute paths to the CRAM files in `"GATKSVPipelineBatch.bam_or_cram_files"`, and provide the absolute paths to the corresponding CRAM index files in `"GATKSVPipelineBatch.bam_or_cram_indexes"`.

## 4. Run on SLURM

Optional scheduler tuning:

```bash
export SLURM_PARTITION=epyc
# export SLURM_ACCOUNT=your_account
# export SLURM_QOS=your_qos
# export SLURM_TIME_LIMIT=7-00:00:00
```

Run Cromwell:

```bash
java -Xmx100G -Dconfig.file=cromwell-slurm.conf -jar cromwell.jar \
  run -i inputs.json wdl/GATKSVPipelineBatch.wdl -o options.json \
  2>&1 | tee cromwell.log
```

## Notes

- `inputs.json` is generated with `GATKSVPipelineBatch.use_melt=true` when `images/local/melt:2.2.2` exists, otherwise `false`.
