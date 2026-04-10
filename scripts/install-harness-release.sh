#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

binary_dir="${HOME}/.local/bin"
binary_path="${binary_dir}/harness"
tmp_path="${binary_path}.new"
signing_identity="Developer ID Application: Bartlomiej Smykla (Q498EB36N4)"

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

command mkdir -p "${binary_dir}"
command rm -f "${tmp_path}"
command cp target/release/harness "${tmp_path}"
command chmod 755 "${tmp_path}"
command codesign --force --options=runtime -s "${signing_identity}" "${tmp_path}"
command chmod 555 "${tmp_path}"
command mv -f "${tmp_path}" "${binary_path}"

cleanup_cli_launch_agent

expected_version="$(target/release/harness --version | command awk '{print $2}')"
installed_version="$("${binary_path}" --version | command awk '{print $2}')"
if [[ "${installed_version}" != "${expected_version}" ]]; then
  printf 'installed harness version %s != expected %s\n' "${installed_version}" "${expected_version}" >&2
  exit 1
fi

command codesign --verify --strict --verbose=2 "${binary_path}" >/dev/null
printf 'installed harness %s at %s\n' "${installed_version}" "${binary_path}"
