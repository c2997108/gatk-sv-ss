version 1.0

import "GatherSampleEvidence.wdl" as gse

workflow SGELocalizeReadsTest {
  input {
    File reads_path
    File reads_index
  }

  call gse.LocalizeReads {
    input:
      reads_path = reads_path,
      reads_index = reads_index,
      move_files = false
  }

  call CheckLocalizedReads {
    input:
      reads_path = LocalizeReads.output_file,
      reads_index = LocalizeReads.output_index
  }

  output {
    File report = CheckLocalizedReads.report
  }
}

task CheckLocalizedReads {
  input {
    File reads_path
    File reads_index
  }

  parameter_meta {
    reads_path: {
      localization_optional: true
    }
    reads_index: {
      localization_optional: true
    }
  }

  command <<<
    set -euo pipefail

    {
      echo "reads_path	~{reads_path}"
      echo "reads_path_resolved	$(readlink -f "~{reads_path}")"
      echo "reads_index	~{reads_index}"
      echo "reads_index_resolved	$(readlink -f "~{reads_index}")"
      test -s "~{reads_path}"
      test -s "~{reads_index}"
      echo "input_check	ok"
    } > sge_localize_reads.report.tsv
  >>>

  output {
    File report = "sge_localize_reads.report.tsv"
  }

  runtime {
    cpu: 1
    memory: "1 GiB"
    disks: "local-disk 10 HDD"
    docker: "ubuntu:18.04"
  }
}
