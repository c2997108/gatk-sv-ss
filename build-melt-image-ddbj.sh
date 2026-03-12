#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build-melt-image-ddbj.sh [options]

Build the MELT Apptainer image for DDBJ without Docker.

Options:
  --melt-tar PATH    Path to MELTv2.2.2.tar.gz
  --output PATH      Output SIF path (default: ./images/local/melt:2.2.2)
  --tmpdir PATH      Apptainer tmp dir (default: /tmp/$USER-apptainer-tmp)
  --cache-dir PATH   Apptainer cache dir (default: /tmp/$USER-apptainer-cache)
  --sandbox PATH     Sandbox path (default: mktemp under /tmp)
  --force            Rebuild even if the output image already exists
  --keep-sandbox     Do not delete the sandbox directory after the build
  --help             Show this help
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
melt_dir="${repo_root}/melt"
output_image="${repo_root}/images/local/melt:2.2.2"
apptainer_tmpdir="/tmp/${USER}-apptainer-tmp"
apptainer_cachedir="/tmp/${USER}-apptainer-cache"
sandbox_dir=""
melt_tar=""
force_build=0
keep_sandbox=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --melt-tar)
      [[ $# -ge 2 ]] || die "--melt-tar requires a value"
      melt_tar="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value"
      output_image="$2"
      shift 2
      ;;
    --tmpdir)
      [[ $# -ge 2 ]] || die "--tmpdir requires a value"
      apptainer_tmpdir="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || die "--cache-dir requires a value"
      apptainer_cachedir="$2"
      shift 2
      ;;
    --sandbox)
      [[ $# -ge 2 ]] || die "--sandbox requires a value"
      sandbox_dir="$2"
      shift 2
      ;;
    --force)
      force_build=1
      shift
      ;;
    --keep-sandbox)
      keep_sandbox=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

require_cmd apptainer
require_cmd unzip
require_cmd install
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  die "wget or curl is required to download GATK"
fi

if [[ -z "${melt_tar}" ]]; then
  for candidate in \
    "${melt_dir}/MELTv2.2.2.tar.gz" \
    "${repo_root}/MELTv2.2.2.tar.gz" \
    "$(dirname "${repo_root}")/MELTv2.2.2.tar.gz"; do
    if [[ -f "${candidate}" ]]; then
      melt_tar="${candidate}"
      break
    fi
  done
fi

[[ -n "${melt_tar}" ]] || die "MELTv2.2.2.tar.gz not found; pass --melt-tar PATH"
[[ -f "${melt_tar}" ]] || die "MELT tarball not found: ${melt_tar}"

gatk_zip="${melt_dir}/gatk-4.2.6.1.zip"
gatk_dir="${melt_dir}/gatk-4.2.6.1"
gatk_jar="${gatk_dir}/gatk-package-4.2.6.1-local.jar"

mkdir -p "${apptainer_tmpdir}" "${apptainer_cachedir}" "$(dirname "${output_image}")"

if [[ -e "${output_image}" && "${force_build}" -ne 1 ]]; then
  echo "output already exists: ${output_image}"
  echo "use --force to rebuild"
  exit 0
fi

if [[ -z "${sandbox_dir}" ]]; then
  sandbox_dir="$(mktemp -d "/tmp/${USER}-melt-pre-sandbox.XXXXXX")"
else
  rm -rf "${sandbox_dir}"
  mkdir -p "${sandbox_dir}"
fi

cleanup() {
  if [[ "${keep_sandbox}" -eq 0 && -n "${sandbox_dir}" && -d "${sandbox_dir}" ]]; then
    rm -rf "${sandbox_dir}"
  fi
}
trap cleanup EXIT

export APPTAINER_TMPDIR="${apptainer_tmpdir}"
export APPTAINER_CACHEDIR="${apptainer_cachedir}"
export TMPDIR="${apptainer_tmpdir}"

if [[ ! -f "${gatk_jar}" ]]; then
  echo "downloading GATK 4.2.6.1 into ${melt_dir}"
  if command -v wget >/dev/null 2>&1; then
    wget -c -O "${gatk_zip}" \
      "https://github.com/broadinstitute/gatk/releases/download/4.2.6.1/gatk-4.2.6.1.zip"
  else
    curl -L -o "${gatk_zip}" \
      "https://github.com/broadinstitute/gatk/releases/download/4.2.6.1/gatk-4.2.6.1.zip"
  fi
  unzip -oq "${gatk_zip}" -d "${melt_dir}"
fi

[[ -f "${gatk_jar}" ]] || die "GATK jar not found after extraction: ${gatk_jar}"

echo "building base sandbox from docker://c2997108/gatk-sv:melt-pre"
apptainer build --sandbox "${sandbox_dir}" docker://c2997108/gatk-sv:melt-pre

mkdir -p "${sandbox_dir}/MELT" "${sandbox_dir}/opt"
tar -xzf "${melt_tar}" -C "${sandbox_dir}/MELT"
install -m 755 "${melt_dir}/run_MELT_2.2.2.sh" "${sandbox_dir}/MELT/run_MELT_2.2.2.sh"
install -m 644 "${gatk_jar}" "${sandbox_dir}/opt/gatk-package-4.2.6.1-local.jar"
ln -sfn /opt/gatk-package-4.2.6.1-local.jar "${sandbox_dir}/opt/gatk.jar"

echo "building final image: ${output_image}"
apptainer build -F "${output_image}" "${sandbox_dir}"

echo "verifying image contents"
apptainer exec "${output_image}" bash -lc '
  set -euo pipefail
  test -f /MELT/MELTv2.2.2/MELT.jar
  test -x /MELT/run_MELT_2.2.2.sh
  test -f /opt/gatk.jar
  command -v bowtie2 >/dev/null
'

echo "built ${output_image}"
echo "MELT tarball: ${melt_tar}"
echo "GATK jar: ${gatk_jar}"
if [[ "${keep_sandbox}" -eq 1 ]]; then
  echo "sandbox kept at ${sandbox_dir}"
fi
