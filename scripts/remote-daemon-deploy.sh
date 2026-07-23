#!/usr/bin/env bash
# Deploy the latest harness-daemon to a live systemd unit on a remote host.
#
# Builds and activates the daemon release set, then hands the freshly activated
# binary to the recorded root-owned harness-systemd controller, which stages,
# verifies, and atomically swaps it under the transactional upgrade contract in
# docs/remote-systemd-upgrades.md. This replaces only the daemon binary of an
# already-installed unit; a newer harness-systemd or a lifecycle-protocol bump
# still needs the manual controller `install` rotation from that runbook.
set -euo pipefail
unalias -a 2>/dev/null || true

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

controller="${HARNESS_REMOTE_SYSTEMD_CONTROLLER:-/usr/local/bin/harness-systemd}"
target_binary="${HARNESS_REMOTE_DAEMON_BINARY:-/usr/local/bin/harness-daemon}"
candidate_dir="${HARNESS_INSTALL_BINARY_DIR:-${HOME}/.local/bin}"
candidate="${HARNESS_REMOTE_DAEMON_CANDIDATE:-${candidate_dir}/harness-daemon}"

passthrough=("$@")

# A dry run must stay non-mutating, so skip the build+activate and only let the
# controller report the transaction it would run against the current candidate.
dry_run=0
for arg in "${passthrough[@]+"${passthrough[@]}"}"; do
  [[ "$arg" == "--dry-run" ]] && dry_run=1
done

if (( dry_run == 0 )); then
  printf 'building and activating the daemon release set\n'
  "$ROOT/scripts/build-and-install-release-set.sh" daemon
fi

# The controller refuses a symbolic-link candidate, and the release-set
# entrypoint is a symlink into the active generation, so hand it the real file.
if [[ -e "$candidate" ]]; then
  candidate="$(readlink -f -- "$candidate")"
fi
if [[ ! -f "$candidate" || ! -x "$candidate" ]]; then
  printf 'candidate daemon is not an executable file at %s\n' "$candidate" >&2
  printf 'activate it first with: mise run install:harness:daemon (or set HARNESS_REMOTE_DAEMON_CANDIDATE)\n' >&2
  exit 1
fi
if [[ ! -f "$controller" || ! -x "$controller" ]]; then
  printf 'harness-systemd controller is not an executable file at %s\n' "$controller" >&2
  printf 'install it once with the runbook in docs/remote-systemd-upgrades.md\n' >&2
  exit 1
fi

# The controller must run as root; the candidate is only ever read as data, so
# it is never elevated.
run_controller() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo -- "$@"
  else
    "$@"
  fi
}

printf 'upgrading %s -> %s via %s\n' "$target_binary" "$candidate" "$controller"
run_controller "$controller" upgrade \
  --candidate-path "$candidate" \
  --binary-path "$target_binary" \
  --json \
  "${passthrough[@]+"${passthrough[@]}"}"
