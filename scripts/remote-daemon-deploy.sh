#!/usr/bin/env bash
# Deploy the latest harness-daemon, and by default the panel, to a live remote host.
#
# Builds and activates the daemon release set, then hands the freshly activated
# binary to the recorded root-owned harness-systemd controller, which stages,
# verifies, and atomically swaps it under the transactional upgrade contract in
# docs/remote-systemd-upgrades.md. This replaces only the daemon binary of an
# already-installed unit; a newer harness-systemd or a lifecycle-protocol bump
# still needs the manual controller `install` rotation from that runbook.
#
# Unless --no-panel is passed, it then does a binary-only harness-panel deploy:
# back up the panel database, swap the panel binary, restart the service, and
# check the loopback health route, restoring the binary and database snapshot on
# failure. The panel has no transactional controller (#604), so a unit, socket,
# or ListenStream change is out of scope here and still needs the manual runbook
# in docs/harness-panel.md. The panel step's host specifics come from
# HARNESS_REMOTE_PANEL_* below.
set -euo pipefail
unalias -a 2>/dev/null || true

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

controller="${HARNESS_REMOTE_SYSTEMD_CONTROLLER:-/usr/local/bin/harness-systemd}"
target_binary="${HARNESS_REMOTE_DAEMON_BINARY:-/usr/local/bin/harness-daemon}"
candidate_dir="${HARNESS_INSTALL_BINARY_DIR:-${HOME}/.local/bin}"
candidate="${HARNESS_REMOTE_DAEMON_CANDIDATE:-${candidate_dir}/harness-daemon}"
unit="${HARNESS_REMOTE_SYSTEMD_UNIT:-}"

panel_candidate="${HARNESS_REMOTE_PANEL_CANDIDATE:-${candidate_dir}/harness-panel}"
panel_binary="${HARNESS_REMOTE_PANEL_BINARY:-/usr/local/bin/harness-panel}"
panel_db="${HARNESS_REMOTE_PANEL_DB:-/var/lib/harness-panel/panel.sqlite3}"
panel_service="${HARNESS_REMOTE_PANEL_SERVICE:-harness-panel.service}"
panel_socket="${HARNESS_REMOTE_PANEL_SOCKET:-harness-panel.socket}"
panel_daemon_unit="${HARNESS_REMOTE_PANEL_DAEMON_UNIT:-harness-remote-daemon.service}"
panel_health_url="${HARNESS_REMOTE_PANEL_HEALTH_URL:-http://127.0.0.1:8787/panel/healthz}"
panel_health_expect="${HARNESS_REMOTE_PANEL_HEALTH_EXPECT:-401}"
panel_backup_root="${HARNESS_REMOTE_PANEL_BACKUP_ROOT:-/var/tmp}"

passthrough=("$@")

# Scan the forwarded flags once. A dry run must stay non-mutating (skip the
# build and activation); an explicit --unit passthrough wins over the
# HARNESS_REMOTE_SYSTEMD_UNIT default so the controller never sees --unit twice;
# and --no-panel is this wrapper's own flag, so it is read here and dropped from
# what reaches the controller, which would reject an unknown flag.
dry_run=0
passthrough_sets_unit=0
no_panel=0
controller_args=()
for arg in "${passthrough[@]}"; do
  case "$arg" in
    --dry-run)
      dry_run=1
      controller_args+=("$arg")
      ;;
    --no-panel) no_panel=1 ;;
    --unit | --unit=*)
      passthrough_sets_unit=1
      controller_args+=("$arg")
      ;;
    *) controller_args+=("$arg") ;;
  esac
done

unit_args=()
if [[ -n "$unit" ]] && (( passthrough_sets_unit == 0 )); then
  unit_args=(--unit "$unit")
fi

# Swapping a binary and driving systemd needs root, but a --dry-run only reports
# and needs no privilege, so nothing here is elevated on a dry run. On a real run
# an unprivileged caller is elevated with sudo. Every candidate is only ever read
# as data by the controller, never executed with sudo.
priv() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo -- "$@"
  else
    "$@"
  fi
}

run_controller() {
  if (( dry_run == 0 )); then
    priv "$@"
  else
    "$@"
  fi
}

# Restore the panel to its pre-deploy state after a failed swap: put the saved
# binary and database snapshot back, bring the panel up on them, and only then
# restart the remote daemon, and only if it was running before and the restored
# panel answers. A restore that itself cannot answer leaves the daemon stopped
# rather than fronting a panel in an unknown state.
rollback_panel() {
  local backup_dir="$1" was_active="$2" status restore_ok=1
  priv systemctl stop "$panel_service" "$panel_socket" || true
  # The binary and database restore are what "restore succeeded" means; the
  # checkpoints around them are best-effort housekeeping. A failed restore must
  # not then front an unknown-state panel with the remote daemon.
  priv install -m 0755 "$backup_dir/harness-panel" "$panel_binary" || restore_ok=0
  priv sqlite3 "$panel_db" 'PRAGMA wal_checkpoint(TRUNCATE)' || true
  priv sqlite3 "$panel_db" ".restore '$backup_dir/panel.sqlite3'" || restore_ok=0
  priv sqlite3 "$panel_db" 'PRAGMA wal_checkpoint(TRUNCATE)' || true
  priv systemctl start "$panel_socket" || true
  priv systemctl start "$panel_service" || true
  status="$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' "$panel_health_url" || true)"
  if [[ "$restore_ok" -eq 1 && "$status" == "$panel_health_expect" && "$was_active" -eq 1 ]]; then
    priv systemctl start "$panel_daemon_unit" || true
  else
    printf 'panel restore incomplete (restore_ok=%s, health %s returned %s); the remote daemon %s was left stopped\n' \
      "$restore_ok" "$panel_health_url" "$status" "$panel_daemon_unit" >&2
  fi
}

# Roll the panel back to its backed-up state and fail the deploy, reporting why.
# Every panel mutation routes its failure here so the remote daemon never stays
# stopped behind an aborted deploy.
panel_rollback_and_fail() {
  local backup_dir="$1" was_active="$2" reason="$3"
  printf 'panel deploy failed: %s; rolling back from %s\n' "$reason" "$backup_dir" >&2
  rollback_panel "$backup_dir" "$was_active"
  printf 'panel deploy failed; backup kept at %s\n' "$backup_dir" >&2
  exit 1
}

# Binary-only panel deploy: back up, swap, restart, verify, and restore on
# failure. The socket keeps owning the listener across the service restart, and
# the remote daemon is stopped for the database snapshot so the backup is taken
# with no writer attached.
deploy_panel() {
  local candidate remote_was_active backup_dir status
  # These feed privileged install/sqlite3/mktemp, so a relative override would
  # read or write CWD-relative paths as root. Require absolute paths, as the
  # controller path already does for its own candidate and binary.
  local pair label path
  for pair in "panel binary:$panel_binary" "panel database:$panel_db" \
    "panel backup root:$panel_backup_root"; do
    label="${pair%%:*}"
    path="${pair#*:}"
    if [[ "$path" != /* ]]; then
      printf '%s must be an absolute path, got %s\n' "$label" "$path" >&2
      exit 1
    fi
  done
  # The release set publishes entrypoints as symlinks and a swap needs the real
  # file, so dereference to an absolute real path as the daemon candidate is.
  candidate="$(readlink -m -- "$panel_candidate")"

  if (( dry_run == 1 )); then
    printf 'would deploy the panel: back up %s, swap %s -> %s, restart %s, check %s == %s\n' \
      "$panel_db" "$panel_binary" "$candidate" "$panel_service" "$panel_health_url" "$panel_health_expect"
    return 0
  fi

  if [[ ! -f "$candidate" || ! -x "$candidate" ]]; then
    printf 'candidate panel is not an executable file at %s\n' "$candidate" >&2
    printf 'activate it first with: mise run install:harness:panel (or set HARNESS_REMOTE_PANEL_CANDIDATE)\n' >&2
    exit 1
  fi

  # Confirm the database before stopping anything: a misconfigured path must cost
  # no downtime, and the snapshot below cannot run without it. `priv test` in a
  # condition also keeps `set -e` from aborting past this explicit message.
  if ! priv test -f "$panel_db"; then
    printf 'panel database not found at %s\n' "$panel_db" >&2
    printf 'set HARNESS_REMOTE_PANEL_DB to the installed database path\n' >&2
    exit 1
  fi

  remote_was_active=0
  if systemctl is-active --quiet "$panel_daemon_unit"; then
    remote_was_active=1
  fi

  backup_dir="$(priv mktemp -d "$panel_backup_root/harness-panel-backup.XXXXXX")"
  printf 'panel rollback copy: %s\n' "$backup_dir"
  priv install -m 0755 "$panel_binary" "$backup_dir/harness-panel"

  # Quiesce the public route, then take a consistent snapshot: the checkpoint
  # folds the WAL back into the main file so the .backup image is whole.
  # The daemon is down from here, so every step routes an explicit failure to
  # rollback. An ERR trap is avoided on purpose: it is not inherited into the
  # `priv` function without `set -E`, so a failure inside `priv` would slip past
  # a caller-level trap; an explicit `|| rollback` is unambiguous.
  priv systemctl stop "$panel_daemon_unit"
  priv sqlite3 "$panel_db" 'PRAGMA wal_checkpoint(TRUNCATE)' \
    || panel_rollback_and_fail "$backup_dir" "$remote_was_active" 'database checkpoint failed'
  priv sqlite3 "$panel_db" ".backup '$backup_dir/panel.sqlite3'" \
    || panel_rollback_and_fail "$backup_dir" "$remote_was_active" 'database backup failed'
  priv install -m 0755 "$candidate" "$panel_binary" \
    || panel_rollback_and_fail "$backup_dir" "$remote_was_active" 'panel binary swap failed'

  # A restart failure is as fatal as a bad health code; capture it rather than
  # letting `set -e` abort with the daemon stopped and the new binary in place.
  if priv systemctl restart "$panel_service"; then
    status="$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' "$panel_health_url" || true)"
  else
    status="restart-failed"
  fi
  if [[ "$status" != "$panel_health_expect" ]]; then
    panel_rollback_and_fail "$backup_dir" "$remote_was_active" \
      "restart/health for $panel_service returned $status (expected $panel_health_expect)"
  fi

  if (( remote_was_active == 1 )); then
    priv systemctl start "$panel_daemon_unit"
  fi
  printf 'panel deployed %s -> %s; rollback copy kept at %s\n' "$panel_binary" "$candidate" "$backup_dir"
}

if (( dry_run == 0 )); then
  if (( no_panel == 0 )); then
    printf 'building and activating the daemon and panel release sets\n'
    "$ROOT/scripts/build-and-install-release-set.sh" daemon panel
  else
    printf 'building and activating the daemon release set\n'
    "$ROOT/scripts/build-and-install-release-set.sh" daemon
  fi
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
# run_controller sudo-executes this path, so a relative override could run a
# binary from the current directory as root. Require an absolute path.
if [[ "$controller" != /* ]]; then
  printf 'harness-systemd controller must be an absolute path, got %s\n' "$controller" >&2
  printf 'set HARNESS_REMOTE_SYSTEMD_CONTROLLER to an absolute path\n' >&2
  exit 1
fi
if [[ ! -f "$controller" || ! -x "$controller" ]]; then
  printf 'harness-systemd controller is not an executable file at %s\n' "$controller" >&2
  printf 'install it once with the runbook in docs/remote-systemd-upgrades.md\n' >&2
  exit 1
fi

printf 'upgrading %s -> %s via %s\n' "$target_binary" "$candidate" "$controller"
run_controller "$controller" upgrade \
  --candidate-path "$candidate" \
  --binary-path "$target_binary" \
  "${unit_args[@]}" \
  --json \
  "${controller_args[@]}"

if (( no_panel == 1 )); then
  printf 'skipping the panel deploy (--no-panel)\n'
else
  deploy_panel
fi
