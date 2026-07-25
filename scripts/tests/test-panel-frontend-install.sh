#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
INSTALLER="$ROOT/scripts/install-panel-frontend.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/panel-frontend-install.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

frontend="$TEST_ROOT/frontend"
fake_npm="$TEST_ROOT/npm"
command mkdir -p "$frontend"
printf '{"lockfileVersion":3}\n' >"$frontend/package-lock.json"

cat >"$fake_npm" <<'FAKE_NPM'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "ci" ]] || exit 2
if ! mkdir .fake-npm-active 2>/dev/null; then
  printf 'concurrent npm ci detected\n' >&2
  exit 90
fi
trap 'rmdir .fake-npm-active 2>/dev/null || true' EXIT

count=0
if [[ -f .fake-npm-count ]]; then
  count="$(cat .fake-npm-count)"
fi
printf '%s\n' "$((count + 1))" >.fake-npm-count
sleep 0.2
mkdir -p node_modules
FAKE_NPM
chmod +x "$fake_npm"

run_installer() {
  HARNESS_PANEL_FRONTEND_DIR="$frontend" \
    HARNESS_PANEL_NPM="$fake_npm" \
    "$INSTALLER"
}

run_installer &
first_pid=$!
run_installer &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

[[ "$(cat "$frontend/.fake-npm-count")" == "1" ]]
cmp -s \
  "$frontend/package-lock.json" \
  "$frontend/node_modules/.harness-panel-stamp"

printf ' \n' >>"$frontend/package-lock.json"
run_installer

[[ "$(cat "$frontend/.fake-npm-count")" == "2" ]]
cmp -s \
  "$frontend/package-lock.json" \
  "$frontend/node_modules/.harness-panel-stamp"

printf 'ok: panel frontend installs are serialized and lockfile-aware\n'
