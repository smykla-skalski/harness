#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
INSTALLER="$ROOT/scripts/install-panel-frontend.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/panel-frontend-install.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

frontend="$TEST_ROOT/frontend"
fake_npm="$TEST_ROOT/npm"
command mkdir -p "$frontend"
printf '{"scripts":{"build":"vite build"}}\n' >"$frontend/package.json"
printf '{"lockfileVersion":3}\n' >"$frontend/package-lock.json"

cat >"$fake_npm" <<'FAKE_NPM'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "ci" ]] || exit 2
[[ "${NODE_ENV:-}" == "production" ]] || exit 3

include_dev=false
for argument in "$@"; do
  if [[ "$argument" == "--include=dev" ]]; then
    include_dev=true
    break
  fi
done
if [[ "$include_dev" != "true" ]]; then
  printf 'npm ci did not include dev dependencies\n' >&2
  exit 4
fi

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
  NODE_ENV=production \
    HARNESS_PANEL_FRONTEND_DIR="$frontend" \
    HARNESS_PANEL_NPM="$fake_npm" \
    "$INSTALLER"
}

assert_stamp_matches_inputs() {
  {
    printf 'package.json\0'
    command cat "$frontend/package.json"
    printf 'package-lock.json\0'
    command cat "$frontend/package-lock.json"
  } >"$TEST_ROOT/expected-stamp"
  cmp -s \
    "$TEST_ROOT/expected-stamp" \
    "$frontend/node_modules/.harness-panel-stamp"
}

run_installer &
first_pid=$!
run_installer &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

[[ "$(cat "$frontend/.fake-npm-count")" == "1" ]]
assert_stamp_matches_inputs

printf ' \n' >>"$frontend/package.json"
run_installer

[[ "$(cat "$frontend/.fake-npm-count")" == "2" ]]
assert_stamp_matches_inputs

printf ' \n' >>"$frontend/package-lock.json"
run_installer

[[ "$(cat "$frontend/.fake-npm-count")" == "3" ]]
assert_stamp_matches_inputs

printf 'ok: panel frontend installs are serialized, dev-complete, and manifest-aware\n'
