# GATK-SV SGE & Singularity fork

このリポジトリは[GATK-SV](https://github.com/broadinstitute/gatk-sv)をSGEとSingularityを用いユーザー権限で実行できるようにソースコードを修正したリポジトリです。オリジナルのバージョンはgatk-sv v2024-06-26です。

# セットアップ手順

## 前提として

下記が必要です

- Linuxサーバー
- SGEがセットアップされていること。私たちはhttps://github.com/daimh/sge でテストしています。
- singularityコマンドがセットアップされていること。私たちはapptainer version 1.1.9-1.el9でテストしています。
- java (version 11以降)がセットアップされていること。

## 必要なファイルのダウンロード

## MELTコンテナの作成

https://melt.igs.umaryland.edu/downloads.php から`MELTv2.2.2.tar.gz`をダウンロードし、meltフォルダーにコピーしておく。

# 実行手順

## CRAMファイルの作成

Parabricksを用いた https://github.com/NCGM-genome/WGSpipeline のパイプラインを使ってFASTQファイルからCRAMファイルを作成する。

## サンプルごとに男女の設定をする
