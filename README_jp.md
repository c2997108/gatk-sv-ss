# GATK-SV-SS

[English README](README.md)

このリポジトリは [Broad GATK-SV](https://github.com/broadinstitute/gatk-sv)
を、オンプレミスのSGEクラスター上で、ユーザー権限のまま
Singularity/Apptainerを使って実行できるようにしたフォークです。
この`main`ブランチはGATK-SV `v1.1`を元にしています。

このブランチで追加した主な機能は以下です。

- CromwellのSGE backend設定
- Singularity実行用および非コンテナ実行用の`qsub`ラッパー
- `gs://`で指定されているGATK-SVリソースをローカルミラーから読む仕組み
- `cram`, `cram2`, `cram3`, ... というフォルダー単位のバッチ実行
- `chrY:2780855-2797682`の平均デプスによるPED sexの自動作成
- 複数バッチの出力をGATK-SVのジョイントコール手順で統合するフロー
- MELTではなくSCRAMbleをデフォルトで使う設定

実装上の変更点の詳細は [SGE_PORT_SUMMARY.md](SGE_PORT_SUMMARY.md) を参照してください。
[v2024-06-26版の手順](https://github.com/c2997108/gatk-sv-ss/blob/v2024-06-26/README_jp.md)
を今回のブランチ向けに更新しています。標準実行に旧版のイメージ一式やMELTのセットアップは必要ありません。

## 必要な環境

このパイプラインは、共有ストレージを持つLinux SGEクラスターで動かすことを想定しています。

Cromwellを起動するサーバーに必要なもの:

- Java 11以降
- Cromwellのメタデータとcall cache用のPostgreSQL
- `jq`
- `samtools`
- `bcftools`, `bgzip`, `tabix`
- Python 3とJinja2（入力JSONの生成に使用）
- Git

SGEの各実行ノードに必要なもの:

- SGE execution daemon
- SingularityまたはApptainer
- リポジトリ、CRAMファイル、リソースミラー、イメージミラーにアクセスできる共有ストレージ

投入サーバーでは`qsub`、`qstat`、`qdel`も必要です。投入ラッパーは並列環境`smp`と
リソース`mem_req`を要求します。サイトのSGE設定に合わせて両方の投入スクリプトを調整してください。
共有ファイルは全ノードから同じ絶対パスで参照できる必要があります。

推奨環境:

- all-SSDの共有ストレージ
- 検体数に応じた十分な作業領域
- 高い共有ストレージ帯域

GATK-SVはI/O負荷がかなり高いパイプラインです。100検体規模でも多くの作業領域が必要になり、ジョイントコールでは大容量メモリのノードが必要になる場合があります。

## リポジトリ構成

今回追加した主なファイル:

- `cromwell-sge.conf`: CromwellのSGE backend設定
- `submit-singularity-job.sh`: コンテナ実行タスク用の`qsub`ラッパー
- `submit-nonsingularity-job.sh`: 非コンテナ実行タスク用の`qsub`ラッパー
- `check-alive.sh`: `qstat`を使ったCromwell job liveness check
- `options.sge.json`: call cacheとローカル出力用のCromwell options
- `prepare-sge-test-inputs.sh`: ローカルCRAM用の`GATKSVPipelineBatch`入力JSONを作るスクリプト
- `run-cramdir-batches-joint.sh`: CRAMフォルダーごとのバッチ実行とジョイント統合を行うメインスクリプト
- `pull-sge-images.sh`: 入力JSONに出てくるDocker imageをSingularity imageとしてローカルに取得するスクリプト
- `wdl/GATKSVPipelineJointBatch.wdl`: バッチ出力を統合して最終cohort VCFを作るWDL

以下の実行結果やローカルミラーはGitの管理対象から外しています。

- `cromwell-executions/`
- `cromwell-outputs/`
- `cromwell-workflow-logs/`
- `sge-cramdir-joint/`
- `sge-test*/`
- ローカルの`gs`および`images`ミラー

## クローン

`main`ブランチを使います。

```bash
git clone https://github.com/c2997108/gatk-sv-ss.git
cd gatk-sv-ss
git switch main
```

以降のコマンドはリポジトリ直下で実行します。初回セットアップの順序は以下です。

1. 必要なコマンド、Cromwell jar、PostgreSQLを用意する。
2. Singularity/Apptainerのパス、共有パスのbind、SGEリソース設定を合わせる。
3. hg38リソースミラー、CRAM/CRAI、depth計算用referenceを用意する。
4. `prepare`で入力を生成し、`pull-sge-images.sh`で必要イメージを取得する。
5. smoke testを確認後、`all`でバッチからジョイントコールまで実行する。

## Cromwell

旧版READMEでは、Singularityのcall cacheとWDL生成ファイルのタイムスタンプに対応した
[修正版Cromwell](https://github.com/c2997108/cromwell/releases/tag/92ky)を使用しています。
そのjarをリポジトリ外に配置する例:

```bash
mkdir -p ../tools
curl -fL -o ../tools/cromwell.jar \
  https://github.com/c2997108/cromwell/releases/download/92ky/cromwell-92-ee3e2b0-SNAP.jar
export GATKSV_CROMWELL_JAR="$(cd ../tools && pwd)/cromwell.jar"
```

指定しない場合、ラッパーは今回の環境固有の以下のパスを使います。

```text
/SSD_ARRAY/gatk-sv_v2024-06-26/cromwell.jar
```

別の場所に置く場合は環境変数で指定します。

```bash
export GATKSV_CROMWELL_JAR=/path/to/cromwell.jar
```

内部的に、各バッチは次の形でCromwellを起動します。

```bash
java -Dconfig.file=/path/to/gatk-sv-ss/cromwell-sge.conf \
  -jar /path/to/cromwell.jar \
  run /path/to/gatk-sv-ss/wdl/GATKSVPipelineBatch.wdl \
  --inputs /path/to/run-root/batches/cram/inputs.GATKSVPipelineBatch.sge.json \
  --options /path/to/gatk-sv-ss/options.sge.json
```

ジョイントコールでは`wdl/GATKSVPipelineJointBatch.wdl`を同様に実行します。

## call cache用PostgreSQL

`cromwell-sge.conf`は`localhost:5432/cromwell`のPostgreSQLを使う設定です。
メタデータを永続化することで、同じ解析を再実行したときに正常終了済みのジョブをcall cacheから再利用できます。

DockerでPostgreSQLを起動する例:

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

停止する場合:

```bash
docker stop cromwell-postgres
```

再開は`docker start cromwell-postgres`です。認証情報は`cromwell-sge.conf`と一致する例です。
環境に合わせて両方を変更してください。DockerはこのDB構築例で使用するもので、実行ノードには不要です。

## Singularity/Apptainerイメージ

SGE backendでは、WDLの`docker` runtime attributeで指定されたイメージを
Singularity/Apptainerで実行します。イメージは以下のディレクトリから解決されます。

```text
${GATKSV_SGE_IMAGE_DIR:-./images}
```

入力JSONを作成した後、必要なイメージを取得します。

```bash
export GATKSV_SINGULARITY_BIN="$(command -v singularity)"
./pull-sge-images.sh sge-cramdir-joint/batches/cram/inputs.GATKSVPipelineBatch.sge.json
```

実行コマンド名が`apptainer`なら、上記の`command -v singularity`を`command -v apptainer`に変更します。
この環境変数を設定しない場合のデフォルトは`/suikou/tool9-all/bin/singularity`です。

別バッチの入力JSONが追加のイメージを使う場合は、その入力JSONでも実行してください。
ローカルのイメージパスはDocker image名をそのまま反映します。

```text
images/us.gcr.io/broad-dsde-methods/gatk-sv/sv-pipeline:2025-09-02-v1.0.5-631368eb
```

今回の`main`ブランチではSCRAMbleをデフォルトで使うため、標準実行ではMELTイメージは不要です。
MELTを明示的に有効にする場合は、MELTのライセンス要件に従ってローカルMELTイメージを別途用意してください。

## ローカルリソースミラー

GATK-SVの入力テンプレートには`gs://`で始まるリソースパスが多く含まれています。
このフォークでは、それらをローカルミラーに置き換えます。

```text
gs://bucket/path/to/file
```

は次のように解決されます。

```text
${GATKSV_RESOURCE_PREFIX}/bucket/path/to/file
```

デフォルトでは、リポジトリ直下に`gs`があれば`GATKSV_RESOURCE_PREFIX=./gs`として扱います。
別の場所を使う場合は以下を指定します。

```bash
export GATKSV_RESOURCE_PREFIX=/path/to/local/gs-mirror
```

このミラーには、生成された入力JSONが参照するGATK-SV public resourcesを入れておく必要があります。
具体的には、reference FASTA/index/dict、1KG reference panel、gCNV model tarball、mask、bin file、clustering/QC resourceなどです。
ラッパーはこれらを自動ダウンロードしません。
`inputs/values/resources_hg38.json`、`inputs/values/ref_panel_1kg.json`と
`prepare-sge-test-inputs.sh`の上書き設定を確認してミラーを用意してください。
旧版のリソース・イメージアーカイブだけでv1.1の必要ファイルが揃うことは確認していません。

## CRAMフォルダー構成

メインラッパーは、以下のような名前のディレクトリをバッチとして扱います。

```text
cram
cram2
cram3
...
```

デフォルトでは、リポジトリの親ディレクトリ直下からこれらを探します。

```text
/analysis/gatk-sv-ss
/analysis/cram
/analysis/cram2
/analysis/cram3
```

各CRAMフォルダーには、各サンプルについて`.cram`と`.cram.crai`を置きます。

```text
cram/
  SAMPLE001.cram
  SAMPLE001.cram.crai
  SAMPLE002.cram
  SAMPLE002.cram.crai
```

サンプルIDはCRAMファイル名から`.cram`を除いた文字列です。
例えば`SAMPLE001.cram`ならサンプルIDは`SAMPLE001`になります。
サンプルIDは全バッチで一意にし、CRAM read groupの`SM`と一致させてください。
サンプルIDやディレクトリパスには空白を使わないでください。
入力テンプレートはhg38用です。CRAMとデコード用referenceもそれに適合するものを使用します。

上記の`/analysis`構成では、コンテナにも共有パスを公開します。

```bash
export GATKSV_SGE_EXTRA_BINDS=/analysis:/analysis
```

CRAMフォルダーを別の場所に置く場合:

```bash
export GATKSV_DATA_ROOT=/path/to/parent-containing-cram-dirs
```

または明示的にディレクトリを指定します。

```bash
./run-cramdir-batches-joint.sh all /path/to/cram /path/to/cram2
```

## PEDと性別判定

複数バッチ用ラッパーは、各バッチのPEDファイルを自動で作成します。
`samtools depth`で次の領域の平均デプスを計算します。

```text
chrY:2780855-2797682
```

判定規則は以下です。

- mean depth `>= 2`: 男性、PED sex `1`
- mean depth `< 2`: 女性、PED sex `2`

生成されるPEDの形式:

```text
sample_id  sample_id  0  0  sex  0
```

列順は家系ID、個体ID、父ID、母ID、sex、表現型です。
各個体を独立した家系として作成するため、実際の血縁関係は保持しません。
sexはデプスから割り当てた値であり、別途確認された性別情報ではありません。

領域や閾値は変更できます。

```bash
export GATKSV_SEX_REGION=chrY:2780855-2797682
export GATKSV_MALE_DEPTH_THRESHOLD=2
```

CRAMのdepth計算にはreference FASTAと`.fai`が必要です。

```bash
export GATKSV_REFERENCE_FASTA=/path/to/Homo_sapiens_assembly38.fasta
```

外部リソースミラーを使う場合は明示的に指定してください。
depth計算用referenceのデフォルトは、別途リポジトリ直下の`gs/`内に設定されています。

## 入力作成のみ

Cromwellを実行せず、バッチmanifest、depth表、PED、入力JSONだけを作る場合:

Jinja2が未導入なら、先に使用するPython環境で`python3 -m pip install Jinja2`を実行します。

```bash
export GATKSV_USE_MELT=false
export GATKSV_USE_SCRAMBLE=true

./run-cramdir-batches-joint.sh prepare
```

作成される主なファイル:

```text
sge-cramdir-joint/batches.tsv
sge-cramdir-joint/all_batches.chrY_2780855_2797682.mean_depth.tsv
sge-cramdir-joint/batches/<batch>/family.ped
sge-cramdir-joint/batches/<batch>/inputs.GATKSVPipelineBatch.sge.json
```

## バッチ実行とジョイントコールをまとめて実行

初回は入力作成、必要なリソースとイメージの取得、後述のsmoke testを済ませてから実行します。
Jinja2が未導入の場合は、使用するPython環境で`python3 -m pip install Jinja2`を実行してください。
通常は次のコマンドで実行します。

```bash
cd /path/to/gatk-sv-ss

export GATKSV_USE_MELT=false
export GATKSV_USE_SCRAMBLE=true

./run-cramdir-batches-joint.sh all
```

このコマンドで行う処理:

1. CRAMフォルダーを検出する
2. chrY領域の平均デプスを計算する
3. バッチごとのPEDを作る
4. バッチごとの`GATKSVPipelineBatch`入力JSONを作る
5. 各バッチで`GATKSVPipelineBatch.wdl`を実行する
6. 成功したバッチmetadataを集める
7. `GATKSVPipelineJointBatch`用の入力JSONを作る
8. ジョイントコールを実行する

バッチは順に実行し、実行中のワークフロー内のタスクを並列化します。
ジョイント処理は`MergeBatchSites`、バッチごとの`GenotypeBatch`、
`RegenotypeCNVs`、`MakeCohortVcf`の順です。
各バッチの成功metadataから以下の10出力を読み取ります。

- `filtered_pesr_vcf`、`filtered_depth_vcf`
- `cutoffs`、`medianfile`
- `merged_coverage_file`、`merged_coverage_file_index`
- `merged_disc_file`、`merged_disc_file_index`
- `merged_split_file`、`merged_split_file_index`

これらのパスをジョイント入力JSONへ直接書き込むため、統合用フォルダーへの手動コピーは不要です。
参照元のファイルは保持してください。共通リソースは先頭バッチの入力から引き継ぐため、
各バッチでリソースと設定を揃えてください。

## 段階的に実行する場合

手動で段階ごとに実行する場合:

```bash
./run-cramdir-batches-joint.sh prepare
./run-cramdir-batches-joint.sh run-batches
./run-cramdir-batches-joint.sh prepare-joint
./run-cramdir-batches-joint.sh run-joint
```

## 失敗後の再実行

同じコマンドをもう一度実行します。

```bash
./run-cramdir-batches-joint.sh all
```

正常終了したバッチのrecovered metadataが存在する場合、ラッパーはそのバッチを再実行せずにスキップします。
また、PostgreSQLと`cromwell-executions/`が残っていれば、Cromwell call cacheにより成功済みのcallが再利用されます。

強制的に作り直す場合:

```bash
export GATKSV_FORCE=true
./run-cramdir-batches-joint.sh all
```

depth表を再生成し、ラッパーの成功済みスキップを解除しますが、Cromwell call cacheは有効なままです。
全タスクの再計算を強制する設定ではありません。使用後は`GATKSV_FORCE`をunsetしてください。
成功済みスキップでは入力変更を比較しないため、サンプル構成や解析設定を変える場合は
新しい`GATKSV_RUN_ROOT`を使ってください。

## 実行時によく使う設定

SGEへの同時投入数は`cromwell-sge.conf`で設定します。

```hocon
concurrent-job-limit = 100
```

Cromwellプロセスごとのbackend上限です。実際に100ジョブが同時実行される保証ではなく、
SGEのスケジューリングやストレージ性能にも制約されます。

問題があるSGEホストを避ける場合:

```bash
export GATKSV_SGE_HOST_EXCLUDES=analysis004,analysis017
```

Singularityに追加でbindするディレクトリを指定する場合:

```bash
export GATKSV_SGE_EXTRA_BINDS=/path1:/path1,/path2:/container/path2
```

Singularity/Apptainerの場所を指定する場合:

```bash
export GATKSV_SINGULARITY_DIR=/path/to/bin
export GATKSV_SINGULARITY_BIN=/path/to/singularity
```

出力rootを変更する場合:

```bash
export GATKSV_RUN_ROOT=/path/to/sge-cramdir-joint
```

## 出力

メインの実行ディレクトリ:

```text
sge-cramdir-joint/
```

重要なファイル:

```text
sge-cramdir-joint/batches.tsv
sge-cramdir-joint/batch_metadata.tsv
sge-cramdir-joint/all_batches.chrY_2780855_2797682.mean_depth.tsv
sge-cramdir-joint/batches/<batch>/metadata.GATKSVPipelineBatch.*.recovered.json
sge-cramdir-joint/joint/inputs.GATKSVPipelineJointBatch.sge.json
sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json
```

各バッチ・jointディレクトリには日時付きのCromwellログも作成されます。
recovered metadataはログから復元したステータスと出力情報であり、全タスクのmetadataではありません。
タスク作業ファイルは`cromwell-executions/`、最終出力の書き出し先は
`options.sge.json`に従い`cromwell-outputs/`です。
`GATKSV_RUN_ROOT`で変更されるのはラッパーの出力先で、これらのCromwellディレクトリではありません。
recovered JSONが複数ある場合は対象の成功実行を選んでください。
以下のワイルドカード例は一致する全ファイルの結果を表示します。

最終clean VCFのパスを取得する例:

```bash
jq -r '.outputs["GATKSVPipelineJointBatch.clean_vcf"]' \
  sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json
```

indexのパス:

```bash
jq -r '.outputs["GATKSVPipelineJointBatch.clean_vcf_index"]' \
  sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json
```

その他の主要なジョイント出力:

```bash
jq -r '.outputs["GATKSVPipelineJointBatch.cohort_depth_vcf"]' \
  sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json

jq -r '.outputs["GATKSVPipelineJointBatch.cohort_pesr_vcf"]' \
  sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json

jq -r '.outputs["GATKSVPipelineJointBatch.master_vcf_qc"]' \
  sge-cramdir-joint/joint/metadata.GATKSVPipelineJointBatch.*.recovered.json
```

## 監視用ヘルパー

今回の解析で使った監視用ヘルパーも含めています。

```bash
./codex-gatksv-monitor-check.sh sge-cramdir-joint/codex-monitor/snapshot.latest.md
./codex-gatksv-monitor-loop.sh start-screen
```

これは運用補助用であり、GATK-SV本体の実行には必須ではありません。
checkスクリプトは状態を記録します。`start-screen`はスクリプト修正や解析再実行を行い得る
Codexの自律監視ループを開始します。`--dangerously-bypass-approvals-and-sandbox`を使用するため、
開始前にプロンプトと設定を確認してください。

## smoke test

入力JSONを作った後、SGE backendで基本的な入力確認を行えます。

```bash
java -Dconfig.file=cromwell-sge.conf \
  -jar "$GATKSV_CROMWELL_JAR" \
  run wdl/SGESmokeTest.wdl \
  --inputs sge-cramdir-joint/batches/cram/inputs.SGESmokeTest.sge.json \
  --options options.sge.json
```

CRAM/CRAI localizationの確認:

```bash
java -Dconfig.file=cromwell-sge.conf \
  -jar "$GATKSV_CROMWELL_JAR" \
  run wdl/SGELocalizeReadsTest.wdl \
  --inputs sge-cramdir-joint/batches/cram/inputs.SGELocalizeReadsTest.sge.json \
  --options options.sge.json
```

## 注意点

- デフォルトのcallerはManta、WHAM、SCRAMbleです。
- このブランチではMELTはデフォルトで無効です。
- 同じ解析を再実行することを前提にしています。成功済みのジョブはCromwell call cacheから再利用されます。
- call cacheを効かせたい場合、`cromwell-executions/`やPostgreSQL databaseを削除しないでください。
- 今回の実行では中間gzipの破損が観測されました。失敗タスクとストレージのログを調べ、破損を確認した出力を退避し、cacheの再利用状況を確認して再開してください。高負荷という事実だけでは原因は確定できません。
