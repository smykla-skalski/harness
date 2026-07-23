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
unit="${HARNESS_REMOTE_SYSTEMD_UNIT:-}"

passthrough=("$@")

# Scan the forwarded flags once: a dry run must stay non-mutating (skip the
# build and activation), and an explicit --unit passthrough wins over the
# HARNESS_REMOTE_SYSTEMD_UNIT default so the controller never sees --unit twice.
dry_run=0
passthrough_sets_unit=0
for arg in "${passthrough[@]+"${passthrough[@]}"}"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --unit | --unit=*) passthrough_sets_unit=1 ;;
  esac
done

unit_args=()
if [[ -n "$unit" ]] && (( passthrough_sets_unit == 0 )); then
  unit_args=(--unit "$unit")
fi

if (( dry_run == 0 )); then
  printf 'building and activating the daemon release set\n'
  "$ROOT/scripts/build-and-install-release-set.sh" daemon
fi

# The controller needs an absolute --candidate-path even for a dry-run and
# refuses a symbolic link, so canonicalize to an absolute real path. readlink -m
# absolutizes a relative override and tolerates a not-yet-built candidate, so a
# --dry-run can preview before activation.
candidate="$(readlink -m -- "$candidate")"
# A real upgrade also needs that path to be an existing regular executable; a
# --dry-run never reads the candidate, so the existence check is skipped.
if (( dry_run == 0 )) && [[ ! -f "$candidate" || ! -x "$candidate" ]]; then
  printf 'candidate daemon is not an executable file at %s\n' "$candidate" >&2
  printf 'activate it first with: mise run install:harness:daemon (or set HARNESS_REMOTE_DAEMON_CANDIDATE)\n' >&2
  exit 1
fi
if [[ ! -f "$controller" || ! -x "$controller" ]]; then
  printf 'harness-systemd controller is not an executable file at %s\n' "$controller" >&2
  printf 'install it once with the runbook in docs/remote-systemd-upgrades.md\n' >&2
  exit 1
fi

# Swapping the binary and driving systemd needs root, but a --dry-run only
# reports and needs no privilege, so it stays unelevated and never prompts for a
# password. The candidate is only ever read as data, never executed with sudo.
run_controller() {
  if (( dry_run == 0 )) && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo -- "$@"
  else
    "$@"
  fi
}

printf 'upgrading %s -> %s via %s\n' "$target_binary" "$candidate" "$controller"
run_controller "$controller" upgrade \
  --candidate-path "$candidate" \
  --binary-path "$target_binary" \
  "${unit_args[@]+"${unit_args[@]}"}" \
  --json \
  "${passthrough[@]+"${passthrough[@]}"}"
