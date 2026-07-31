#!/usr/bin/env bash
set -euo pipefail

# remote-daemon-deploy.sh is a Linux-only operator wrapper (it uses GNU
# `readlink -m` and drives systemd), so exercise it only where it can run.
if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'test-remote-daemon-deploy: skipped on %s\n' "$(uname -s)"
  exit 0
fi

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/remote-daemon-deploy-test.XXXXXX")"

cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

fail() {
  printf 'test-remote-daemon-deploy: %s\n' "$*" >&2
  exit 1
}

# A fake repo root so the script resolves its sibling build script to our stub.
repo="$SANDBOX/repo"
mkdir -p "$repo/scripts"
cp "$ROOT/scripts/remote-daemon-deploy.sh" "$repo/scripts/remote-daemon-deploy.sh"
chmod +x "$repo/scripts/remote-daemon-deploy.sh"
deploy_script="$repo/scripts/remote-daemon-deploy.sh"

# The build stub records that it ran instead of building anything.
build_marker="$SANDBOX/build-ran"
cat >"$repo/scripts/build-and-install-release-set.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$build_marker"
EOF
chmod +x "$repo/scripts/build-and-install-release-set.sh"

# The controller stub records the exact argv the wrapper hands it.
controller="$SANDBOX/harness-systemd"
ctrl_args="$SANDBOX/controller-args"
cat >"$controller" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$ctrl_args"
EOF
chmod +x "$controller"

# A fake sudo lets the real-run path proceed without privilege: it drops the
# leading -- and runs the rest, so the stub controller still receives the argv.
fakebin="$SANDBOX/bin"
mkdir -p "$fakebin"
cat >"$fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--" ]] && shift
exec "$@"
EOF
chmod +x "$fakebin/sudo"

candidate="$SANDBOX/harness-daemon"
cp "$controller" "$candidate"

# Panel stubs: the binary-only panel deploy drives systemd, sqlite3, and curl.
# Each stub records its calls; curl prints a controllable health code and
# systemctl reports the remote daemon active by default.
systemctl_log="$SANDBOX/systemctl-calls"
sqlite_log="$SANDBOX/sqlite-calls"
cat >"$fakebin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$systemctl_log"
if [[ "\${1:-}" == "is-active" ]]; then
  [[ "\${FAKE_DAEMON_ACTIVE:-1}" == "1" ]] && exit 0 || exit 3
fi
if [[ "\${1:-}" == "restart" && "\${FAKE_RESTART_FAIL:-0}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
cat >"$fakebin/sqlite3" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$sqlite_log"
[[ "\${FAKE_SQLITE_FAIL:-0}" == "1" ]] && exit 1
exit 0
EOF
cat >"$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${FAKE_HEALTH_CODE:-401}"
EOF
chmod +x "$fakebin/systemctl" "$fakebin/sqlite3" "$fakebin/curl"

# Sandbox stand-ins for the host paths the panel step touches.
panel_binary="$SANDBOX/usr-local-bin/harness-panel"
panel_candidate="$SANDBOX/local-bin/harness-panel"
panel_db="$SANDBOX/panel.sqlite3"
panel_backup_root="$SANDBOX/backups"
mkdir -p "$SANDBOX/usr-local-bin" "$SANDBOX/local-bin" "$panel_backup_root"
printf 'new-panel' >"$panel_candidate"
chmod +x "$panel_candidate"
touch "$panel_db"

reset_panel() {
  printf 'old-panel' >"$panel_binary"
  chmod +x "$panel_binary"
  rm -f "$systemctl_log" "$sqlite_log"
}
reset_panel

deploy() {
  PATH="$fakebin:$PATH" \
    HARNESS_REMOTE_SYSTEMD_CONTROLLER="$controller" \
    HARNESS_REMOTE_DAEMON_CANDIDATE="$candidate" \
    HARNESS_REMOTE_PANEL_CANDIDATE="$panel_candidate" \
    HARNESS_REMOTE_PANEL_BINARY="$panel_binary" \
    HARNESS_REMOTE_PANEL_DB="$panel_db" \
    HARNESS_REMOTE_PANEL_BACKUP_ROOT="$panel_backup_root" \
    "$@"
}

count_lines() {
  grep -cx -- "$1" "$2" || true
}

# A --dry-run must not build or activate anything, and must forward the flag.
rm -f "$build_marker" "$ctrl_args"
deploy "$deploy_script" --dry-run >/dev/null
[[ ! -e "$build_marker" ]] || fail "--dry-run invoked the build script"
grep -qx -- '--dry-run' "$ctrl_args" || fail "--dry-run not forwarded to the controller"

# A real run does build+activate and never forwards --dry-run (the contrast that
# makes the skip above meaningful).
rm -f "$build_marker" "$ctrl_args"
deploy "$deploy_script" >/dev/null
[[ -e "$build_marker" ]] || fail "real run skipped the build script"
grep -qx -- 'upgrade' "$ctrl_args" || fail "controller not invoked on a real run"
if grep -qx -- '--dry-run' "$ctrl_args"; then
  fail "real run forwarded --dry-run"
fi

# An explicit --unit passthrough wins over HARNESS_REMOTE_SYSTEMD_UNIT, so the
# controller sees exactly one --unit carrying the passthrough value.
rm -f "$ctrl_args"
HARNESS_REMOTE_SYSTEMD_UNIT=envunit \
  deploy "$deploy_script" --dry-run --unit passunit >/dev/null
unit_count="$(count_lines '--unit' "$ctrl_args")"
[[ "$unit_count" -eq 1 ]] || fail "expected one --unit, got $unit_count"
grep -qx -- 'passunit' "$ctrl_args" || fail "passthrough --unit value missing"
if grep -qx -- 'envunit' "$ctrl_args"; then
  fail "env unit leaked past the --unit passthrough"
fi

# With no passthrough --unit, the env default is injected once.
rm -f "$ctrl_args"
HARNESS_REMOTE_SYSTEMD_UNIT=envunit \
  deploy "$deploy_script" --dry-run >/dev/null
[[ "$(count_lines '--unit' "$ctrl_args")" -eq 1 ]] || fail "env unit not injected once"
grep -qx -- 'envunit' "$ctrl_args" || fail "env unit value missing"

# The default release-set candidate is a symlink (install-release-set.sh
# publishes stable entrypoints as symlinks) and the controller refuses one, so a
# real run must forward the dereferenced real path, not the symlink.
rm -f "$build_marker" "$ctrl_args"
link_candidate="$SANDBOX/link-daemon"
ln -sf "$candidate" "$link_candidate"
real_candidate="$(readlink -m -- "$candidate")"
# --no-panel keeps this focused on the daemon candidate; the panel path has its
# own coverage below and needs its stubbed host paths, which this inline run does
# not set.
PATH="$fakebin:$PATH" \
  HARNESS_REMOTE_SYSTEMD_CONTROLLER="$controller" \
  HARNESS_REMOTE_DAEMON_CANDIDATE="$link_candidate" \
  "$deploy_script" --no-panel >/dev/null
forwarded_candidate="$(awk '/^--candidate-path$/{getline; print; exit}' "$ctrl_args")"
[[ "$forwarded_candidate" == "$real_candidate" ]] \
  || fail "controller got '$forwarded_candidate', expected real path '$real_candidate'"
if [[ "$forwarded_candidate" == "$link_candidate" ]]; then
  fail "controller received the symlink path instead of the dereferenced real path"
fi

# A relative controller override is rejected before any sudo execution, so a
# planted binary in the current directory cannot be run as root.
rm -f "$ctrl_args"
set +e
reject_out="$(
  PATH="$fakebin:$PATH" \
    HARNESS_REMOTE_SYSTEMD_CONTROLLER="relative-controller" \
    HARNESS_REMOTE_DAEMON_CANDIDATE="$candidate" \
    "$deploy_script" --dry-run 2>&1
)"
reject_rc=$?
set -e
[[ "$reject_rc" -ne 0 ]] || fail "relative controller path was accepted"
grep -q 'must be an absolute path' <<<"$reject_out" \
  || fail "relative controller did not report the absolute-path requirement"
[[ ! -e "$ctrl_args" ]] || fail "relative controller was executed"

# A default real run builds the panel too and swaps its binary, restarting the
# service and checking the health route.
rm -f "$build_marker" "$ctrl_args"
reset_panel
deploy "$deploy_script" >/dev/null
grep -qx -- 'daemon' "$build_marker" || fail "default run did not build the daemon"
grep -qx -- 'panel' "$build_marker" || fail "default run did not build the panel"
[[ "$(cat "$panel_binary")" == 'new-panel' ]] || fail "default run did not swap the panel binary"
grep -qx -- 'restart harness-panel.service' "$systemctl_log" \
  || fail "default run did not restart the panel service"

# --no-panel restores the daemon-only behavior: no panel build, no panel steps,
# and the flag is this wrapper's own, never forwarded to the controller.
rm -f "$build_marker" "$ctrl_args"
reset_panel
deploy "$deploy_script" --no-panel >/dev/null
grep -qx -- 'daemon' "$build_marker" || fail "--no-panel did not build the daemon"
if grep -qx -- 'panel' "$build_marker"; then
  fail "--no-panel still built the panel"
fi
[[ "$(cat "$panel_binary")" == 'old-panel' ]] || fail "--no-panel swapped the panel binary"
[[ ! -s "$systemctl_log" ]] || fail "--no-panel drove systemd"
grep -qx -- 'upgrade' "$ctrl_args" || fail "--no-panel skipped the daemon upgrade"
if grep -qx -- '--no-panel' "$ctrl_args"; then
  fail "--no-panel leaked to the controller"
fi

# A --dry-run previews the panel without building or touching the host.
rm -f "$build_marker" "$ctrl_args"
reset_panel
dry_out="$(deploy "$deploy_script" --dry-run)"
[[ ! -e "$build_marker" ]] || fail "--dry-run built the release set"
[[ "$(cat "$panel_binary")" == 'old-panel' ]] || fail "--dry-run swapped the panel binary"
[[ ! -s "$systemctl_log" ]] || fail "--dry-run drove systemd"
grep -q 'would deploy the panel' <<<"$dry_out" || fail "--dry-run did not preview the panel"

# A health code other than the expected one rolls the binary back and fails.
rm -f "$ctrl_args"
reset_panel
set +e
health_out="$(FAKE_HEALTH_CODE=500 deploy "$deploy_script" 2>&1)"
health_rc=$?
set -e
[[ "$health_rc" -ne 0 ]] || fail "a failed health check did not fail the deploy"
[[ "$(cat "$panel_binary")" == 'old-panel' ]] || fail "a failed health check did not restore the panel binary"
grep -q 'rolling back' <<<"$health_out" || fail "a failed health check did not report a rollback"

# A panel service that fails to restart is as fatal as a bad health code: it must
# roll the binary back and fail, not abort under set -e with the new binary in
# place and the daemon left stopped.
rm -f "$ctrl_args"
reset_panel
set +e
restart_out="$(FAKE_RESTART_FAIL=1 deploy "$deploy_script" 2>&1)"
restart_rc=$?
set -e
[[ "$restart_rc" -ne 0 ]] || fail "a failed panel restart did not fail the deploy"
[[ "$(cat "$panel_binary")" == 'old-panel' ]] || fail "a failed panel restart did not restore the panel binary"
grep -q 'rolling back' <<<"$restart_out" || fail "a failed panel restart did not report a rollback"

# A snapshot failure after the daemon is stopped must roll back and bring the
# daemon back up, not abort under set -e with the daemon left stopped.
rm -f "$ctrl_args"
reset_panel
set +e
snap_out="$(FAKE_SQLITE_FAIL=1 deploy "$deploy_script" 2>&1)"
snap_rc=$?
set -e
[[ "$snap_rc" -ne 0 ]] || fail "a failed snapshot did not fail the deploy"
[[ "$(cat "$panel_binary")" == 'old-panel' ]] || fail "a failed snapshot still swapped the panel binary"
grep -qx -- 'start harness-remote-daemon.service' "$systemctl_log" \
  || fail "a failed snapshot left the remote daemon stopped"
grep -q 'rolling back' <<<"$snap_out" || fail "a failed snapshot did not report a rollback"

printf 'test-remote-daemon-deploy: ok\n'
