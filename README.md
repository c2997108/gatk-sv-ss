[日本語版 (Japanese)](https://github.com/c2997108/gatk-sv-ss/blob/v2024-06-26/README_jp.md)

---

# GATK-SV fork with SGE & Singularity

This repository is a modified version of [GATK-SV](https://github.com/broadinstitute/gatk-sv) that can be executed with user privileges using SGE and Singularity.
The original version is gatk-sv v2024-06-26.

For DDBJ / SLURM usage, see [README_ddbj_slurm.md](README_ddbj_slurm.md).

# Setup Instructions

## Prerequisites

The following are required:

* A Linux server (if merging 500 samples, a server with 512 GB of memory is required)
* SGE must be set up. We tested with [https://github.com/daimh/sge](https://github.com/daimh/sge)
* Docker must be installed (only required on the main server where Cromwell is launched)
* Java (version 11 or later) must be installed (only required on the main server where Cromwell is launched)
* The `singularity` command must be installed on all servers. We tested with apptainer version 1.1.9-1.el9

For the working directory, approximately 20 TB of free disk space is required for 100 samples.

## Download Required Files

```bash
git clone https://github.com/c2997108/gatk-sv-ss.git
cd gatk-sv-ss
# Fix paths
sed -i 's%/SSD_ARRAY/gatk-sv_v2024-06-26/tmp%'"$PWD"'%; s%/suikou/tool9-all/bin%'"$(dirname $(which singularity))"'%' cromwell-sge.conf

# Download Singularity container images and genome data required to run GATK-SV
wget -O gatk-sv-singularity.tar.gz https://zenodo.org/records/17994642/files/gatk-sv-singularity.tar.gz?download=1
tar vxf gatk-sv-singularity.tar.gz 

# Download a modified Cromwell JAR for Singularity execution.
# It is modified so that caching works across re-runs when using container image names,
# and so that files created by WDL write_lines have fixed timestamps to enable caching.
wget -O cromwell.jar https://github.com/c2997108/cromwell/releases/download/92ky/cromwell-92-97d07e0-SNAP.jar
```

## Building the MELT Container

Due to licensing restrictions, files must be downloaded from the author’s website.
Download `MELTv2.2.2.tar.gz` from
[https://melt.igs.umaryland.edu/downloads.php](https://melt.igs.umaryland.edu/downloads.php)
and copy it into the `melt` directory.

```bash
cd melt
wget https://github.com/broadinstitute/gatk/releases/download/4.2.6.1/gatk-4.2.6.1.zip
unzip -oq gatk-4.2.6.1.zip
docker build -t local/melt:2.2.2 .
docker save -o melt.tar local/melt:2.2.2
mkdir -p ../images/local
singularity build ../images/local/melt:2.2.2 docker-archive://melt.tar
cd ..
```

On environments where Docker is unavailable, `melt/Apptainer.melt.def` can be used as a starting point for an Apptainer-native build. On DDBJ, see `README_ddbj_slurm.md` for the tested sandbox-to-SIF workflow.
For the DDBJ supercomputer specifically, `build-melt-image-ddbj.sh` automates the tested non-Docker build.

# Execution Procedure

## 1. Generate CRAM Files (+ gVCF Files)

Use the WGS pipeline developed by Dr. Yatsuya et al.
[https://github.com/NCGM-genome/WGSpipeline](https://github.com/NCGM-genome/WGSpipeline)
(This is a WGS pipeline mainly based on NVIDIA Parabricks.)

We confirmed that it can be run with a single GeForce RTX 4060 Ti 16GB GPU.
A concrete demo is shown below.

```bash
python -m venv cwlenv
source cwlenv/bin/activate
python -m pip install --upgrade pip
pip install cwltool
git clone https://github.com/NCGM-genome/WGSpipeline.git
OUTDIR=reference_hg38 ; mkdir -p $OUTDIR ; for url in `cat WGSpipeline/download_links/reference_hg38.download_links.txt` ; do echo $url ; file=`basename $url` ; if [ ! -f ${OUTDIR}/$file ] ; then wget $url -O ${OUTDIR}/$file ; fi ; done

# To download 1000 Genomes sequencing data as test data, use the following commands.
OUTDIR=wgs_fastq ; mkdir -p $OUTDIR ; for url in `cat WGSpipeline/download_links/wgs_fastq_NA12878_20k.download_links.txt` ; do echo $url ; file=`basename $url` ; if [ ! -f ${OUTDIR}/$file ] ; then wget $url -O ${OUTDIR}/$file ; fi ; done

mkdir -p tutorial_01
cwltool --singularity \
    --enable-ext \
    --outdir tutorial_01 \
    WGSpipeline/Workflows/germline-gpu.cwl \
    --ref reference_hg38/Homo_sapiens_assembly38.fasta \
    --fq1 wgs_fastq/H06HDADXX130110.1.ATCACGAT.20k_reads_1.fastq \
    --fq2 wgs_fastq/H06HDADXX130110.1.ATCACGAT.20k_reads_2.fastq \
    --rg "@RG\\tID:NA12878.H06HDADXX130110.1\\tPL:ILLUMINA\\tPU:H06HDADXX130110.1\\tLB:H06HDADXX130110.1\\tSM:NA12878" \
    --num_gpus 1 \
    --prefix NA12878.H06HDADXX130110.1 \
    --autosome_interval WGSpipeline/interval_files/autosome.bed \
    --PAR_interval WGSpipeline/interval_files/PAR.bed \
    --chrX_interval WGSpipeline/interval_files/chrX.bed \
    --chrY_interval WGSpipeline/interval_files/chrY.bed
```

Copy all generated `.cram` and `.cram.crai` files into the `cram` directory.
If sex determination is performed from VCFs, copy `chrY.vcf.gz` and `chrY.vcf.gz.tbi` files into the `gvcf` directory.

Since all tools introduced here are executed inside containers, running them via symbolic links requires knowledge about directory binding.
If unsure, **copy the files or create hard links instead (important!).**

```bash
# Example copy commands:
cp -p tutorial_01/*.cram* cram/
cp -p tutorial_01/*.chrY.g.vcf.gz* gvcf/
```

## 2. Specify Sex for Each Sample

### a. Determine Sex from gVCF and Create a PED File

```bash
# Example: classify as female if average depth of the SRY gene is ≤ 2, otherwise male
for i in gvcf/*.chrY.g.vcf.gz; do
 sname=`zcat $i|grep -v "^##"|head -n 1|cut -f 10`;
 docker run -v "$PWD:$PWD" -w "$PWD" -it --rm biocontainers/bcftools:v1.9-1-deb_cv1 bcftools view $i chrY:2780855-2797682|grep -v "^#"|cut -f 10|cut -f 2 -d:|awk -F, -v name="$sname" '{for(i=1;i<=NF;i++){a+=$i}; n++} END{print name"\t"a/n}';
done | awk -F'\t' '{if($2>2){s=1}else{s=2}; print $1"\t"$1"\t0\t0\t"s"\t0"}' > family.ped
```

### b. Create a PED File from Sample Metadata

Create a tab-delimited `family.ped` file with one sample per line, for example:

| Sample name | Family name | 0 | 0 | (1 for male, 2 for female) | 0 |
| ----------- | ----------- | - | - | -------------------------- | - |
| male_1      | family_1    | 0 | 0 | 1                          | 0 |
| female_1    | family_1    | 0 | 0 | 2                          | 0 |

## 3. Prepare a JSON File Listing CRAM Files

```bash
ls cram/*.cram |awk '
 FILENAME==ARGV[1]{n=split($0,arr,"/"); sub(/[.]cram$/,"",arr[n]); id[FNR]=arr[n]; file[FNR]=$0; m=FNR}
 FILENAME==ARGV[2]{
  if($1=="\"GATKSVPipelineBatch.samples\":"){ORS=""; print "  \"GATKSVPipelineBatch.samples\": [\""id[1]"\""; for(i=2;i<=m;i++){print ",\""id[i]"\""}; ORS="\n"; print "],"}
  else if($1=="\"GATKSVPipelineBatch.bam_or_cram_files\":"){ORS=""; print "  \"GATKSVPipelineBatch.bam_or_cram_files\": [\""file[1]"\""; for(i=2;i<=m;i++){print ",\""file[i]"\""}; ORS="\n"; print "],"}
  else{print $0}
 }' /dev/stdin inputs-template.json > inputs.json
```

## 4. Run GATK-SV

```bash
# Start a database to record progress so completed tasks can be reused on re-runs
mkdir -p cromwell-pgdata
chmod 777 cromwell-pgdata
docker run -d --name cromwell-postgres \
    -e POSTGRES_PASSWORD=cromwellpw \
    -e POSTGRES_USER=cromwell \
    -e POSTGRES_DB=cromwell \
    -v "$PWD"/cromwell-pgdata:/var/lib/postgresql/data \
    -p 5432:5432 postgres:15       

# Run GATK-SV analysis.
# Depending on cluster size, on a cluster of ~30 nodes (12 cores, 128 GB each),
# processing 100 samples takes about one week.
# An all-SSD NFS shared filesystem is recommended.
# During analysis, read/write throughput of ~20 Gbps is constantly used.
java -Xmx100G -Dconfig.file=cromwell-sge.conf -jar cromwell.jar run -i inputs.json wdl/GATKSVPipelineBatch.wdl -o options.json 2>&1 | tee cromwell.log
```

```bash
# To stop the PostgreSQL Docker container
docker stop cromwell-postgres
```

## 5. Noise Filtering

Using the tool we developed below, it is possible to remove about half of false-positive SVs without losing true SVs.
This tool uses deep learning, and we confirmed it can run with a single GeForce RTX 4060 Ti 16GB GPU.

[https://github.com/Endo2001/EMSVfilter](https://github.com/Endo2001/EMSVfilter)

```bash
# Remove noise SVs that can be filtered without machine learning
zcat cromwell-outputs/batch1.cleaned.vcf.gz |grep -v "^##"|awk -F'\t' '
 NR==1{print $0}
 NR>1{
  n1++
  if(!($5=="<DUP>"&&$8~"ALGORITHMS=depth;EVIDENCE=RD$")){
   n2++
   split($8,arr,";"); e=substr(arr[1],5); s=$2; s2=s-500; e2=e+500; l=e2-s2; s3=s2-l*0.1; e3=e2+l*0.1; if(s3<=0){s3=1};
   if(e3-s3<10*1000*1000){
    n3++
    cont=0; for(i=10;i<=NF;i++){split($i,arr2,":"); split(arr2[1],arr3,"/"); if(arr3[2]=="0"){cont=i; break}}
    if(cont!=0){
     n4++
     print $0
    }
   }
  }
 }
 END{print "Total: "n1"\nFiltered low quality DUP SVs: "n1-n2"\nFiltered very large SVs: "n2-n3"\nFiltered no 0/0 SVs: "n3-n4"\nRemained: "n4 > "/dev/stderr"}
' > output.cleaned.tsv

# Extract IDs to take IGV screenshots for running EMSVfilter.
# As controls, also take screenshots at the same coordinates for samples where the variant is not detected.
awk -F'\t' '
 NR==1{for(i=10;i<=NF;i++){name[i]=$i}}
 NR>1{
  split($8,arr,";"); e=substr(arr[1],5); s=$2; s2=s-500; e2=e+500; l=e2-s2; s3=s2-l*0.1; e3=e2+l*0.1; if(s3<=0){s3=1};
  if(e3-s3<10*1000*1000){
   cont=0; for(i=10;i<=NF;i++){split($i,arr2,":"); split(arr2[1],arr3,"/"); if(arr3[2]=="0"){cont=i; break}};
   if(cont!=0){
    for(i=10;i<=NF;i++){split($i,arr2,":"); split(arr2[1],arr3,"/"); if(arr3[2]=="1"){printf "%s-%s-%s\t%s\t%d\t%d\t%s\t%s\n", $1,$2,$3,$1,s3,e3,name[i],name[cont]}}
   }
  }
 }' output.cleaned.tsv > check.list

# Create a batch file for taking screenshots in IGV
# Installing IGV is required. bgzip and tabix are required if you want to display gene annotations together.
# For reference, the IGV version used to train EMSVfilter was 2.16.2.
ref=/path/to/reference_hg38/Homo_sapiens_assembly38.fasta
wget https://ftp.ensembl.org/pub/release-84/gtf/homo_sapiens/Homo_sapiens.GRCh38.84.gtf.gz
zcat Homo_sapiens.GRCh38.84.gtf.gz | LC_ALL=C sort -t$'\t' -k1,1 -k4,4n -k5,5n | bgzip > Homo_sapiens.GRCh38.84.sorted.gtf.gz
tabix -p gff Homo_sapiens.GRCh38.84.sorted.gtf.gz
gtf=Homo_sapiens.GRCh38.84.sorted.gtf.gz
mkdir -p igv-image
awk -F'\t' -v ref="$ref" -v gtf="$gtf" '
 BEGIN{
    print "new"
    print "genome "ref
 }
 {
        print "new"
        print "goto "$2":"$3"-"$4
        print "load "gtf
        print "load cram/"$5".cram"
        print "viewaspairs\ncollapse\ngroup reference_concordance"
        print "snapshot igv-image/sample_"$1"-"$3"-"$4"-"$5".png"
        print "new"
        print "goto "$2":"$3"-"$4
        print "load "gtf
        print "load cram/"$6".cram"
        print "viewaspairs\ncollapse\ngroup reference_concordance"
        print "snapshot igv-image/control_"$1"-"$3"-"$4"-"$5".png"
}' check.list > run-igv.batch

## To run without X (headless)
# xvfb-run -a -s "-screen 0 1600x1000x24 -nolisten tcp" /path/to/igv.sh -b run-igv.batch

## To run with X (GUI), run directly
/path/to/igv.sh -b run-igv.batch

# Run EMSVfilter
docker run -it --rm --gpus all -v "$PWD:$PWD" -w "$PWD" c2997108/emsvfilter:0.1 EMSVfilter.py igv-image > result.txt

```
