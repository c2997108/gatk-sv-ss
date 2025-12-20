#!/usr/bin/env bash
memory_gb="$1"
cpu="$2"
basedir="$3"
job_name="$4"
cwd="$5"
out="$6"
err="$7"
singularitydir="$8"
docker="$9"
script="${10}"

          MEM_G_PER_CORE=`echo "scale=3; ${memory_gb}/${cpu}"|bc`G
          dockerimagedir="${basedir}/images"
          while true; do
            job_id=$(
              qsub \
               -terse \
               -V \
               -b y \
               -N ${job_name} \
               -wd ${cwd} \
               -o ${out} \
               -e ${err} \
               -pe smp ${cpu} \
               -l mem_req=$MEM_G_PER_CORE \
               -v JAVA_TOOL_OPTIONS="-XX:+UseSerialGC -XX:CICompilerCount=2" \
               ${singularitydir}/singularity exec --no-home --bind ${cwd}:${cwd} --bind "${basedir}/gs:/gs" --bind "${basedir}/cromwell-executions:/cromwell-executions" --pwd "${cwd}" "${dockerimagedir}/${docker}" bash ${script}
            )

            status=$?

            if [ $status -eq 0 ]; then
              echo "${job_id}"
              break
            else
              #echo "qsub failed. Retry in 10 seconds..."
              sleep 10
            fi
          done
