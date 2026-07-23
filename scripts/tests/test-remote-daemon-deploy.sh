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

deploy() {
  PATH="$fakebin:$PATH" \
    HARNESS_REMOTE_SYSTEMD_CONTROLLER="$controller" \
    HARNESS_REMOTE_DAEMON_CANDIDATE="$candidate" \
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
PATH="$fakebin:$PATH" \
  HARNESS_REMOTE_SYSTEMD_CONTROLLER="$controller" \
  HARNESS_REMOTE_DAEMON_CANDIDATE="$link_candidate" \
  "$deploy_script" >/dev/null
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

printf 'test-remote-daemon-deploy: ok\n'
