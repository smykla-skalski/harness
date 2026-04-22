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

candidate_version() {
  local candidate="$1"
  "${candidate}" --version 2>/dev/null | command awk '{print $2}'
}

candidate_is_harness_cli() {
  local candidate="$1"
  "${candidate}" --help 2>/dev/null | command grep -Fq "Harness CLI"
}

shadow_reconciliation_opted_out() {
  local candidate="$1"
  local cargo_home cargo_binary
  cargo_home="${CARGO_HOME:-${HOME}/.cargo}"
  cargo_binary="${cargo_home}/bin/harness"

  [[ "${HARNESS_INSTALL_REMOVE_CARGO_SHADOW:-1}" == "0" ]] \
    && [[ "${candidate}" == "${cargo_binary}" ]]
}

reconcile_shadowed_harness_binary() {
  local candidate="$1"
  local candidate_dir tmp_shadow
  candidate_dir="$(dirname -- "${candidate}")"
  tmp_shadow="${candidate}.new"

  if shadow_reconciliation_opted_out "${candidate}"; then
    printf 'warning: leaving shadowed cargo harness binary at %s because HARNESS_INSTALL_REMOVE_CARGO_SHADOW=0\n' "${candidate}" >&2
    return 1
  fi

  if ! candidate_is_harness_cli "${candidate}"; then
    printf 'warning: refusing to overwrite non-harness CLI shadow binary at %s\n' "${candidate}" >&2
    return 1
  fi

  if [[ ! -w "${candidate_dir}" ]]; then
    printf 'warning: unable to reconcile shadowed harness binary at %s because %s is not writable\n' \
      "${candidate}" "${candidate_dir}" >&2
    return 1
  fi

  command rm -f "${tmp_shadow}"
  if ! command ln -s "${binary_path}" "${tmp_shadow}"; then
    printf 'warning: unable to stage reconciled harness binary at %s\n' "${tmp_shadow}" >&2
    command rm -f "${tmp_shadow}"
    return 1
  fi

  if ! command mv -f "${tmp_shadow}" "${candidate}"; then
    printf 'warning: unable to reconcile shadowed harness binary at %s\n' "${candidate}" >&2
    command rm -f "${tmp_shadow}"
    return 1
  fi

  printf 'reconciled shadowed harness binary at %s -> %s\n' "${candidate}" "${binary_path}" >&2
}

reconcile_shadowed_harness_binaries() {
  local candidate candidate_ver
  local -a unresolved_candidates=()

  IFS=: read -r -a path_entries <<< "${PATH:-}"
  for path_entry in "${path_entries[@]}"; do
    [[ -n "${path_entry}" ]] || continue
    candidate="${path_entry}/harness"
    [[ -x "${candidate}" ]] || continue
    [[ -n "${candidate}" ]] || continue
    if [[ "${candidate}" == "${binary_path}" ]] || [[ "${candidate}" -ef "${binary_path}" ]]; then
      continue
    fi

    candidate_ver="$(candidate_version "${candidate}")"
    if [[ -z "${candidate_ver}" ]]; then
      unresolved_candidates+=("${candidate}")
      printf 'warning: unable to determine version for shadowed harness binary at %s\n' "${candidate}" >&2
      continue
    fi
    if [[ "${candidate_ver}" == "${installed_version}" ]]; then
      continue
    fi

    if ! reconcile_shadowed_harness_binary "${candidate}"; then
      unresolved_candidates+=("${candidate}")
      continue
    fi

    candidate_ver="$(candidate_version "${candidate}")"
    if [[ "${candidate_ver}" != "${installed_version}" ]]; then
      printf 'warning: shadowed harness binary at %s still reports version %s after reconciliation\n' \
        "${candidate}" "${candidate_ver:-unknown}" >&2
      unresolved_candidates+=("${candidate}")
    fi
  done

  if (( ${#unresolved_candidates[@]} > 0 )); then
    printf "unable to reconcile shadowed harness binary path(s); clean them up before using \`harness\`:\n" >&2
    for candidate in "${unresolved_candidates[@]}"; do
      printf '  - %s\n' "${candidate}" >&2
    done
    exit 1
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
    if [[ "${candidate}" == "${binary_path}" ]] || [[ "${candidate}" -ef "${binary_path}" ]]; then
      continue
    fi
    [[ -x "${candidate}" ]] || continue

    candidate_version="$(candidate_version "${candidate}")"
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
    printf "warning: if an existing shell still resolves an older harness binary, run \`rehash\` or start a new shell after removing the shadowed path\n" >&2
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

reconcile_shadowed_harness_binaries

if [[ "${skip_codesign}" != "1" ]]; then
  command codesign --verify --strict --verbose=2 "${binary_path}" >/dev/null
fi
warn_shadowed_harness_binaries
printf 'installed harness %s at %s\n' "${installed_version}" "${binary_path}"
