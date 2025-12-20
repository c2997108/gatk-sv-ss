# GATK-SV SGE & Singularity fork

このリポジトリは[GATK-SV](https://github.com/broadinstitute/gatk-sv)をSGEとSingularityを用いユーザー権限で実行できるようにソースコードを修正したリポジトリです。オリジナルのバージョンはgatk-sv v2024-06-26です。

# セットアップ手順

## 前提として

下記が必要です

- Linuxサーバー
- SGEがセットアップされていること。私たちはhttps://github.com/daimh/sge でテストしています。
- dockerがセットアップされていること。
- singularityコマンドがセットアップされていること。私たちはapptainer version 1.1.9-1.el9でテストしています。
- java (version 11以降)がセットアップされていること。

## 必要なファイルのダウンロード

```
git clone https://github.com/c2997108/gatk-sv.git
cd gatk-sv
```

## MELTコンテナの作成

ライセンスの関係で作者のHPからファイルをダウンロードしてくる必要がある。
https://melt.igs.umaryland.edu/downloads.php から`MELTv2.2.2.tar.gz`をダウンロードし、meltフォルダーにコピーしておく。

```
cd melt
docker build -t local/melt:2.2.2 .
docker save -o melt.tar local/melt:2.2.2
mkdir -p ../images/local
singularity build ../images/local/melt:2.2.2 docker-archive://melt.tar
cd ..
```

# 実行手順

## CRAMファイルの作成

Parabricksを用いた https://github.com/NCGM-genome/WGSpipeline のパイプラインを使ってFASTQファイルからCRAMファイルを作成し、作成されたcram、cram.craiファイルはすべてcramフォルダーにコピーしておく。コンテナ内実行の関係で、シンボリックリンクには現在対応していないので、コピーもしくはハードリンクを作成すること！（重要）

## サンプルごとに男女を判定し設定ファイルを作成する

```
for i in cram4.gvcfY/*.chrY.g.vcf.gz; do j=`echo $i|sed 's/.chrY.g.vcf.gz$//'`; /suikou/tool9/bcftools-1.17/bin/bcftools view $i chrY:2780855-2797682|grep -v "^#"|cut -f 10|cut -f 2 -d:|awk -F, -v name=`basename $j` '{for(i=1;i<=NF;i++){a+=$i}; n++} END{print name"\t"a/n}'; done |sort |awk -F'\t' '{if($2>2){s=1}else{s=2}; print $1"\t"$1"\t0\t0\t"s"\t0"}' > SRYcov.ped
```

## 入力ファイルを記述したjsonファイルを準備する

