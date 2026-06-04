version 1.0

workflow SGESmokeTest {
  input {
    String ped_file
    Array[String] cram_files
    Array[String] crai_files
    String linux_docker = "ubuntu:18.04"
  }

  call CheckLocalInputs {
    input:
      ped_file = ped_file,
      cram_files = cram_files,
      crai_files = crai_files,
      linux_docker = linux_docker
  }

  output {
    File report = CheckLocalInputs.report
  }
}

task CheckLocalInputs {
  input {
    String ped_file
    Array[String] cram_files
    Array[String] crai_files
    String linux_docker
  }

  command <<<
    set -euo pipefail

    {
      echo "ped_file	~{ped_file}"
      echo "ped_lines	$(awk 'END { print NR }' "~{ped_file}")"
      echo "cram_count	~{length(cram_files)}"
      echo "crai_count	~{length(crai_files)}"

      for path in ~{sep=" " cram_files}; do
        test -s "${path}"
      done
      for path in ~{sep=" " crai_files}; do
        test -s "${path}"
      done
      echo "input_check	ok"
    } > sge_smoke_test.report.tsv
  >>>

  output {
    File report = "sge_smoke_test.report.tsv"
  }

  runtime {
    cpu: 1
    memory: "1 GiB"
    disks: "local-disk 10 HDD"
    docker: linux_docker
  }
}
