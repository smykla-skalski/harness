#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

binary_dir="${AFF_INSTALL_BINARY_DIR:-${HARNESS_INSTALL_BINARY_DIR:-${HOME}/.local/bin}}"
binary_path="${binary_dir}/aff"
tmp_path="${binary_path}.new"
signing_identity="${AFF_INSTALL_SIGNING_IDENTITY:-${HARNESS_INSTALL_SIGNING_IDENTITY:-Developer ID Application: Bartlomiej Smykla (Q498EB36N4)}}"
skip_codesign="${AFF_INSTALL_SKIP_CODESIGN:-${HARNESS_INSTALL_SKIP_CODESIGN:-0}}"
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

resolve_target_dir() {
  if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    printf '%s\n' "${CARGO_TARGET_DIR}"
    return 0
  fi

  local target_dir
  target_dir="$(
    "${ROOT}/scripts/cargo-local.sh" --print-env \
      | command awk -F= '/^CARGO_TARGET_DIR=/{print $2}'
  )"

  if [[ -z "${target_dir}" ]]; then
    printf 'failed to resolve CARGO_TARGET_DIR via scripts/cargo-local.sh --print-env\n' >&2
    exit 1
  fi

  printf '%s\n' "${target_dir}"
}

target_dir="$(resolve_target_dir)"
build_binary="${target_dir}/release/aff"

if [[ "${1:-}" == "--print-build-binary" ]]; then
  printf '%s\n' "${build_binary}"
  exit 0
fi

trap 'command rm -f "${tmp_path}"' EXIT

command mkdir -p "${binary_dir}"
if [[ ! -x "${build_binary}" ]]; then
  printf 'expected release binary missing at %s\n' "${build_binary}" >&2
  exit 1
fi

command rm -f "${tmp_path}"
command cp "${build_binary}" "${tmp_path}"
command chmod 755 "${tmp_path}"
if [[ "${skip_codesign}" != "1" ]]; then
  command codesign --force --options=runtime -s "${signing_identity}" "${tmp_path}"
fi
command chmod 555 "${tmp_path}"
command mv -f "${tmp_path}" "${binary_path}"

expected_version="$("${build_binary}" --version | command awk '{print $2}')"
installed_version="$("${binary_path}" --version | command awk '{print $2}')"
if [[ "${installed_version}" != "${expected_version}" ]]; then
  printf 'installed aff version %s != expected %s\n' "${installed_version}" "${expected_version}" >&2
  exit 1
fi

if [[ "${skip_codesign}" != "1" ]]; then
  command codesign --verify --strict --verbose=2 "${binary_path}" >/dev/null
fi

printf 'installed aff %s at %s\n' "${installed_version}" "${binary_path}"
