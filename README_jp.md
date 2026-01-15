# GATK-SV fork with SGE & Singularity

このリポジトリは[GATK-SV](https://github.com/broadinstitute/gatk-sv)をSGEとSingularityを用いユーザー権限で実行できるようにソースコードを修正したリポジトリです。オリジナルのバージョンはgatk-sv v2024-06-26です。

# セットアップ手順

## 前提として

下記が必要です

- Linuxサーバー（500検体をマージするなら512GBのメモリーのサーバーが必要）
- SGEがセットアップされていること。私たちはhttps://github.com/daimh/sge でテストしています。
- dockerがセットアップされていること。cromwellを起動するメインサーバーのみでOK。
- java (version 11以降)がセットアップされていること。cromwellを起動するメインサーバーのみでOK。
- singularityコマンドがセットアップされていること。全サーバーに必要。私たちはapptainer version 1.1.9-1.el9でテストしています。

作業するフォルダーの空き容量は100検体で20TBほど必要。

## 必要なファイルのダウンロード

```
git clone https://github.com/c2997108/gatk-sv-ss.git
cd gatk-sv-ss
# Pathの修正
sed -i 's%/SSD_ARRAY/gatk-sv_v2024-06-26/tmp%'"$PWD"'%; s%/suikou/tool9-all/bin%'"$(dirname $(which singularity))"'%' cromwell-sge.conf

# singularityのコンテナイメージやGATK-SVの実行に必要なゲノムデータなどをダウンロード
wget -O gatk-sv-singularity.tar.gz https://zenodo.org/records/17994642/files/gatk-sv-singularity.tar.gz?download=1
tar vxf gatk-sv-singularity.tar.gz 

# singularityの実行用に修正したcromwellファイルをダウンロード。コンテナのイメージ名で起動しても再実行時にキャッシュが効くように、またWDLのwrite_linesを使った場合に作成されるファイルのタイムスタンプを固定することで再実行時にキャッシュが効くように修正している。
wget -O cromwell.jar https://github.com/c2997108/cromwell/releases/download/92ky/cromwell-92-97d07e0-SNAP.jar
```

## MELTコンテナの作成

ライセンスの関係で作者のHPからファイルをダウンロードしてくる必要がある。
https://melt.igs.umaryland.edu/downloads.php から`MELTv2.2.2.tar.gz`をダウンロードし、meltフォルダーに`MELTv2.2.2.tar.gz`をコピーしておく。

```
cd melt
wget https://github.com/broadinstitute/gatk/releases/download/4.2.6.1/gatk-4.2.6.1.zip
tar vxf gatk-4.2.6.1.zip
docker build -t local/melt:2.2.2 .
docker save -o melt.tar local/melt:2.2.2
mkdir -p ../images/local
singularity build ../images/local/melt:2.2.2 docker-archive://melt.tar
cd ..
```

# 実行手順

## 1. CRAMファイル (+ gVCFファイル)の作成

八谷先生らが開発されているhttps://github.com/NCGM-genome/WGSpipeline (NVIDIA Parabricksを中心としたWGSパイプライン)を使ってFASTQファイルからCRAMファイルを作成する。私たちはGeForce RTX 4060 Ti 16GB 1枚で実行できることを確認した。具体的なデモは下記の通り。

```
python -m venv cwlenv
source cwlenv/bin/activate
python -m pip install --upgrade pip
pip install cwltool
git clone https://github.com/NCGM-genome/WGSpipeline.git
OUTDIR=reference_hg38 ; mkdir -p $OUTDIR ; for url in `cat WGSpipeline/download_links/reference_hg38.download_links.txt` ; do echo $url ; file=`basename $url` ; if [ ! -f ${OUTDIR}/$file ] ; then wget $url -O ${OUTDIR}/$file ; fi ; done

#テストデータとして1000ゲノムのシーケンスデータを使う場合は下記のコマンドでダウンロード。
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

作成されたcram、cram.craiファイルはすべてcramフォルダーにコピーしておく。男女の判定をVCFから行う場合は、gVCFのchrY.vcf.gz, chrY.vcf.gz.tbiファイルをgvcfフォルダーにコピーしておく。基本的に今回紹介するツールはいずれもコンテナ内で実行するため、シンボリックリンクで動作させるにはディレクトリのバインドについて知っておく必要があり、わからない場合はコピーもしくはハードリンクを作成すること！（重要）

```
# コピーコマンドの例：
cp -p tutorial_01/*.cram* cram/
cp -p tutorial_01/*.chrY.g.vcf.gz* gvcf/
```

## 2. サンプルごとに男女を記述する

### a. gVCFから判定し設定ファイル(ped)を作成する場合

```
# SRY遺伝子の平均デプスが2以下なら女性、2より大きければ男性と判定する例
for i in gvcf/*.chrY.g.vcf.gz; do
 sname=`zcat $i|grep -v "^##"|head -n 1|cut -f 10`;
 docker run -v "$PWD:$PWD" -w "$PWD" -it --rm biocontainers/bcftools:v1.9-1-deb_cv1 bcftools view $i chrY:2780855-2797682|grep -v "^#"|cut -f 10|cut -f 2 -d:|awk -F, -v name="$sname" '{for(i=1;i<=NF;i++){a+=$i}; n++} END{print name"\t"a/n}';
done | awk -F'\t' '{if($2>2){s=1}else{s=2}; print $1"\t"$1"\t0\t0\t"s"\t0"}' > family.ped
```

### b. サンプルの情報から性別を記述したpedファイルを作成する場合

| サンプル名 | 家族名 | 0 | 0 | ( 男性なら1, 女性なら2) | 0 |
| --- | --- | --- | --- | --- | --- | 
| male_1 | family_1 | 0 | 0 | 1 | 0 |
| female_1 | family_1 | 0 | 0 | 2 | 0 |

のようなタブ区切りテキストを1行1サンプルで記述したfamily.pedを作成。

## 3. cramファイルを記述したjsonファイルを準備する

```
ls cram/*.cram |awk '
 FILENAME==ARGV[1]{n=split($0,arr,"/"); sub(/[.]cram$/,"",arr[n]); id[FNR]=arr[n]; file[FNR]=$0; m=FNR}
 FILENAME==ARGV[2]{
  if($1=="\"GATKSVPipelineBatch.samples\":"){ORS=""; print "  \"GATKSVPipelineBatch.samples\": [\""id[1]"\""; for(i=2;i<=m;i++){print ",\""id[i]"\""}; ORS="\n"; print "],"}
  else if($1=="\"GATKSVPipelineBatch.bam_or_cram_files\":"){ORS=""; print "  \"GATKSVPipelineBatch.bam_or_cram_files\": [\""file[1]"\""; for(i=2;i<=m;i++){print ",\""file[i]"\""}; ORS="\n"; print "],"}
  else{print $0}
 }' /dev/stdin inputs-template.json > inputs.json
```

## 4. GATK-SVの実行

```
# やり直す場合に正常終了した部分の結果を再利用できるように進行状況を記録するDBを起動しておく
mkdir -p cromwell-pgdata
chmod 777 cromwell-pgdata
docker run -d --name cromwell-postgres \
    -e POSTGRES_PASSWORD=cromwellpw \
    -e POSTGRES_USER=cromwell \
    -e POSTGRES_DB=cromwell \
    -v "$PWD"/cromwell-pgdata:/var/lib/postgresql/data \
    -p 5432:5432 postgres:15       

# GATK-SVの解析を実行　サーバーの規模によるが、12コア 128GB x 30台ほどの規模のクラスターでは100検体で1週間ほどかかる。共有ディスクはオールSSDのNFSを推奨。解析中は読み書きともに常時20Gbps程度で使用される。
java -Xmx100G -Dconfig.file=cromwell-sge.conf -jar cromwell.jar run -i inputs.json wdl/GATKSVPipelineBatch.wdl -o options.json 2>&1 | tee cromwell.log
```

```
# postgresのdockerを止める場合は
docker stop cromwell-postgres
```

## 5. ノイズ除去

私たちが開発している下記のツールを使うと、真のSVを失うことなく擬陽性のSVを半分除去することが可能である。ディープラーニングを使用しており、GeForce RTX 4060 Ti 16GB 1枚で実行できることを確認した。

https://github.com/Endo2001/EMSVfilter

```
# 機械学習を使うまでもなく削除可能なノイズSVを除去
zcat cromwell-outputs/batch1.cleaned.vcf.gz |grep -v "^##"|awk -F'\t' '
 NR==1{print $0}
 NR>1{
  n1++
  if(!($5=="<DUP>"&&$8~"ALGORITHMS=depth;EVIDENCE=RD$")){ #DUP変異でデプスだけでコールされている変異はほぼノイズなので除去
   n2++
   split($8,arr,";"); e=substr(arr[1],5); s=$2; s2=s-500; e2=e+500; l=e2-s2; s3=s2-l*0.1; e3=e2+l*0.1; if(s3<=0){s3=1};
   if(e3-s3<10*1000*1000){ #10Mbを超える変異はほぼノイズなので除去
    n3++
    cont=0; for(i=10;i<=NF;i++){split($i,arr2,":"); split(arr2[1],arr3,"/"); if(arr3[2]=="0"){cont=i; break}}
    if(cont!=0){ #全検体中で0/0が呼び出されていない変異はノイズか、全員が持っている頻度の高い変異なので除去
     n4++
     print $0
    }
   }
  }
 }
 END{print "Total: "n1"\nFiltered low quality DUP SVs: "n1-n2"\nFiltered very large SVs: "n2-n3"\nFiltered no 0/0 SVs: "n3-n4"\nRemained: "n4 > "/dev/stderr"}
' > output.cleaned.tsv

# EMSVfilterを実行するためにIGVで各SVのスクリーンショットを撮る。コントロールとして同じ座標で変異の検出されない検体のSVも撮影する。そのためのIDを抽出。
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

# IGVでスクリーンショットを撮るためのバッチファイル作成
# IGVのインストールは必須。bgzip, tabixは遺伝子アノテーションを一緒に表示させたいならば必要。
# EMSVfilterの学習に使用したIGVのバージョンを一応書いておくと、2.16.2
# IGVのView -> Preferences -> Alignmentsで、あらかじめVisibility range threshold (kb): 300000にし、
# Filter duplicate reads, Filter vendor failed reads, Filter secondary alignments, Show soft-clipped basesのチェックを入れておくこと。
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
## Xなしで実行するなら
# xvfb-run -a -s "-screen 0 1600x1000x24 -nolisten tcp" /path/to/igv.sh -b run-igv.batch
## Xありで実行するなら直接実行
/path/to/igv.sh -b run-igv.batch

# EMSVfilterの実行
docker run -it --rm --gpus all -v "$PWD:$PWD" -w "$PWD" c2997108/emsvfilter:0.1 EMSVfilter.py igv-image > result.txt
```
