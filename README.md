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

作業するフォルダーの空き容量は100検体で20TBほど必要。

## 必要なファイルのダウンロード

```
git clone https://github.com/c2997108/gatk-sv.git
cd gatk-sv
sed -i 's%/SSD_ARRAY/gatk-sv_v2024-06-26/tmp%'"$PWD"'%; s%/suikou/tool9-all/bin%'"$(dirname $(which singularity))"'%' cromwell-sge.conf

# singularityのコンテナイメージやGATK-SVの実行に必要なゲノムデータなどをダウンロード
wget -O gatk-sv-singularity.tar.gz https://zenodo.org/records/17994642/files/gatk-sv-singularity.tar.gz?download=1
tar vxf gatk-sv-singularity.tar.gz 

# singularityの実行用に修正したcromwellファイルをダウンロード。コンテナのイメージ名で起動しても再実行時にキャッシュが効くように、またWDLのwrite_linesを使った場合に作成されるファイルのタイムスタンプを固定することで再実行時にキャッシュが効くように修正している。
wget -O cromwell.jar https://github.com/c2997108/cromwell/releases/download/92ky/cromwell-92-97d07e0-SNAP.jar
```

## MELTコンテナの作成

ライセンスの関係で作者のHPからファイルをダウンロードしてくる必要がある。
https://melt.igs.umaryland.edu/downloads.php から`MELTv2.2.2.tar.gz`をダウンロードし、meltフォルダーにコピーしておく。

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

Parabricksを用いた https://github.com/NCGM-genome/WGSpipeline のパイプラインを使ってFASTQファイルからCRAMファイルを作成し、作成されたcram、cram.craiファイルはすべてcramフォルダーにコピーしておく。男女の判定をVCFから行う場合は、gVCFのchrY.vcf.gz, chrY.vcf.gz.tbiファイルをgvcfフォルダーにコピーしておく。コンテナ内実行の関係で、シンボリックリンクには現在対応していないので、コピーもしくはハードリンクを作成すること！（重要）

```
# コピーコマンドの例：
cp -p /path/to/CRAM/*/CRAM/*cram* cram/
cp -p /path/to/gVCF/*/VCF/*chrY.vcf.gz* gvcf/
```

## 2. サンプルごとに男女を記述する

### a. gVCFから判定し設定ファイル(ped)を作成する場合

```
# SRY遺伝子の平均デプスが2以下なら女性、2より大きければ男性と判定する例
for i in gvcf/*.chrY.vcf.gz; do
 sname=`zcat $i|grep -v "^##"|head -n 1|cut -f 10`;
 docker run -v "$PWD:$PWD" -w "$PWD" -it --rm biocontainers/bcftools:v1.9-1-deb_cv1 bcftools view $i chrY:2780855-2797682|grep -v "^#"|cut -f 10|cut -f 2 -d:|awk -F, -v name="$sname" '{for(i=1;i<=NF;i++){a+=$i}; n++} END{print name"\t"a/n}';
done | awk -F'\t' '{if($2>2){s=1}else{s=2}; print $1"\t"$1"\t0\t0\t"s"\t0"}' > family.ped
```

### b. サンプルの情報から性別を記述したpedファイルを作成する場合

| サンプル名 | 家族名 | 0 | 0 | ( 男性なら1, 女性なら2) | 0 |
| --- | --- | --- | --- | --- | --- | 
| male_1 | family_1 | 0 | 0 | 1 | 0 |
| female_1 | family_1 | 0 | 0 | 2 | 0 |

のタブ区切りテキストを作成し、family.pedを作成。

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

## 4. 実行

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

# GATK-SVの解析を実行　サーバーの規模によるが、12コアx30台ほどの規模のクラスターでは100検体で1週間ほどかかる。共有ディスクはオールSSDのNFSを推奨。解析中は読み書きともに常時20Gbps程度で使用される。
java -Xmx100G -Dconfig.file=cromwell-sge.conf -jar cromwell.jar run -i inputs.json wdl/GATKSVPipelineBatch.wdl -o options.json 2>&1 | tee cromwell.log
```

```
# postgresのdockerを止める場合は
docker stop cromwell-postgres
```

## 5. ノイズ除去

https://github.com/Endo2001/EMSVfilter

```
cromwell-outputs/batch1.cleaned.vcf.gz


for i in resultall6/snp-sv.*.sort2.txt.filtered.txt; do
 a=`tail -n+6 $i|awk -F'\t' 'NR==1||($4!="SV_end"&&$4!="")'|awk -F'\t' 'NR==1||!($6=="<DUP>"&&$0~"ALGORITHMS=depth;EVIDENCE=RD\t")'`;
 if [ `echo "$a"|wc -l` != 1 ]; then
  echo "$a"|awk -F'\t' '
   BEGIN{
    print "new"
    print "genome /ddca2/original/2021-11-17-WGS2/hdd1/Homo_sapiens_assembly38.fasta"
    print "load /suikou/db/genome/GRCh38/Homo_sapiens.GRCh38.84.sorted.gtf"
   }
   FILENAME==ARGV[1]{fam[$1]=$6; id[$1]=$7; if($3=="患者"){ispat[$1]="patient"}else{ispat[$1]="normal"}}
   FILENAME==ARGV[2]{
    if(FNR==1){for(i=1;i<=NF;i++){if($i=="FORMAT"){s=i+1}else if($i=="SV_type"){t=i}; name[i]=$i; name2index[$i]=i}}
    else if(NR>1){
     if($4-$3>10*1000*1000){next} #10Mbp以上のSVはスキップ
       url=$1; gsub("http://localhost:60151/load.file=","",url); #$1=http://localhost:60151/load?file=T:/cram/DC0000090654.cram,T:/cram/DC0000090670.cram&genome=hg38&locus=chr1:25643125-25644125
       split(url, arr0, "&genome=hg38&locus="); split(arr0[1],arr,","); #arr0[1]=T:/cram/DC0000090654.cram,T:/cram/DC0000090670.cram
       split(arr0[2],x0,":"); split(x0[2],x1,"-");x1size=x1[2]-x1[1]; #arr0[2]=chr1:25643125-25644125, x0[1]=chr1
       x1[1]=int(x1[1]-x1size*0.1)
       if(x1[1]<1){x1[1]=1}
       x1[2]=int(x1[2]+x1size*0.1)
     for(i=s;i<=NF;i++){ #患者家系以外で正常検体を見つける
      if($i!=""&&substr($i,1,1)==0&&substr($i,3,1)==0){
       for(j in arr){ #arr[1]=T:/cram/DC0000090654.cram, arr[2]=T:/cram/DC0000090670.cram
        split(arr[j],arr2,"/"); split(arr2[length(arr2)],arr3,"."); #arr3[1]=DC0000090654
        item=$name2index[arr3[1]]
        g1=substr(item,1,1)
        g2=substr(item,3,1)
        gsub("T:/cram/","",arr[j]) #arr[j]=DC0000090654.cram
        print "new"
        print "goto "x0[1]":"x1[1]"-"x1[2]
        print "load /suikou/db/genome/GRCh38/Homo_sapiens.GRCh38.84.sorted.gtf"
        print "load cram/"arr[j]
        print "viewaspairs\ncollapse\ngroup reference_concordance"
        print "snapshot image2/sample_"x0[1]"_"$3"_"$4"__"$t"__"fam[arr3[1]]"__"ispat[arr3[1]]"__"g1"-"g2"__"id[arr3[1]]"__"arr3[1]".png"
        #print "remove "arr[j]
        print "new"
        print "goto "x0[1]":"x1[1]"-"x1[2]
        print "load /suikou/db/genome/GRCh38/Homo_sapiens.GRCh38.84.sorted.gtf"
        print "load cram/"name[i]".cram"
        print "viewaspairs\ncollapse\ngroup reference_concordance"
        print "snapshot image2/control_"x0[1]"_"$3"_"$4"__"$t"__"fam[arr3[1]]"__"ispat[arr3[1]]"__"g1"-"g2"__"id[arr3[1]]"__"arr3[1]".png"
        #print "remove "name[i]".cram"
       }
       break
      }
     }
    }
   }
   END{print "exit"}' <(cat kanja.txt|sed 's/\r//'|awk -F'\t' '{OFS="\t"; gsub(/ $/,"",$6); gsub(/[^a-zA-Z0-9._=-]/,"_",$6); gsub(/ $/,"",$7); gsub(/[^a-zA-Z0-9._=-]/,"_",$7); print $0}') /dev/stdin > run2.batch;
 xvfb-run -a -s "-screen 0 1600x1000x24 -nolisten tcp" /suikou/download9/IGV_Linux_2.19.6/igv.sh -b run2.batch
 fi;
done;
```
