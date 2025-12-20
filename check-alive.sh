#!/bin/bash

job_id=$1
jobcheck=`qstat -j ${job_id} 2>&1`
e=`echo $?`
#ジョブが正常終了しているとqstat -jがエラー1で、Following jobs...とメッセージが出るので、その場合のみ正常終了としてエラーコード１で終了
#それ以外はqstatのトラブルでエラーが出たとみなして継続
if [ "$e" = "1" ];then
 if [ `echo $jobcheck|grep "Following jobs do not exist"|wc -l` = 1 ];then
  sleep 30
  exit 1
 else
  exit 0
 fi
else
 exit 0
fi
