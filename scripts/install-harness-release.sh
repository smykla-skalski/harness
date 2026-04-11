#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

binary_dir="${HARNESS_INSTALL_BINARY_DIR:-${HOME}/.local/bin}"
binary_path="${binary_dir}/harness"
tmp_path="${binary_path}.new"
signing_identity="${HARNESS_INSTALL_SIGNING_IDENTITY:-Developer ID Application: Bartlomiej Smykla (Q498EB36N4)}"
skip_codesign="${HARNESS_INSTALL_SKIP_CODESIGN:-0}"
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
build_binary="${target_dir}/release/harness"

if [[ "${1:-}" == "--print-build-binary" ]]; then
  printf '%s\n' "${build_binary}"
  exit 0
fi

trap 'command rm -f "${tmp_path}"' EXIT

run_for_cli_daemon_root() {
  command env -u HARNESS_APP_GROUP_ID -u HARNESS_DAEMON_DATA_HOME -u HARNESS_SANDBOXED "$@"
}

cleanup_cli_launch_agent() {
  if [[ "${HARNESS_INSTALL_CLEANUP_CLI_DAEMON:-1}" == "0" ]]; then
    return
  fi

  if ! run_for_cli_daemon_root "${binary_path}" daemon stop --json >/dev/null 2>&1; then
    printf 'warning: unable to stop existing CLI daemon; continuing binary install\n' >&2
  fi
  if ! run_for_cli_daemon_root "${binary_path}" daemon remove-launch-agent --json >/dev/null 2>&1; then
    printf 'warning: unable to remove existing CLI launch agent; continuing binary install\n' >&2
  fi
}

warn_shadowed_harness_binaries() {
  local candidate candidate_version first_resolved=""
  local printed_shell_guidance=0

  IFS=: read -r -a path_entries <<< "${PATH:-}"
  for path_entry in "${path_entries[@]}"; do
    [[ -n "${path_entry}" ]] || continue
    candidate="${path_entry}/harness"
    [[ -x "${candidate}" ]] || continue
    [[ -n "${candidate}" ]] || continue
    if [[ -z "${first_resolved}" ]]; then
      first_resolved="${candidate}"
    fi
    [[ "${candidate}" == "${binary_path}" ]] && continue
    [[ -x "${candidate}" ]] || continue

    candidate_version="$("${candidate}" --version 2>/dev/null | command awk '{print $2}')"
    [[ -n "${candidate_version}" ]] || continue
    [[ "${candidate_version}" == "${installed_version}" ]] && continue

    printf 'warning: PATH also contains %s (harness %s) which differs from installed harness %s at %s\n' \
      "${candidate}" "${candidate_version}" "${installed_version}" "${binary_path}" >&2
    printed_shell_guidance=1
  done

  if [[ -n "${first_resolved}" && "${first_resolved}" != "${binary_path}" ]]; then
    printf 'warning: command resolution currently prefers %s over the installed binary %s\n' \
      "${first_resolved}" "${binary_path}" >&2
    printed_shell_guidance=1
  fi

  if [[ "${printed_shell_guidance}" == "1" ]]; then
    printf 'warning: if an existing shell still resolves an older harness binary, run `rehash` or start a new shell after removing the shadowed path\n' >&2
  fi
}

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

cleanup_cli_launch_agent

expected_version="$("${build_binary}" --version | command awk '{print $2}')"
installed_version="$("${binary_path}" --version | command awk '{print $2}')"
if [[ "${installed_version}" != "${expected_version}" ]]; then
  printf 'installed harness version %s != expected %s\n' "${installed_version}" "${expected_version}" >&2
  exit 1
fi

if [[ "${skip_codesign}" != "1" ]]; then
  command codesign --verify --strict --verbose=2 "${binary_path}" >/dev/null
fi
warn_shadowed_harness_binaries
printf 'installed harness %s at %s\n' "${installed_version}" "${binary_path}"
