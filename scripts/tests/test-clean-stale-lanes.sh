#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/clean-stale-lanes.sh"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
TEST_TMP_ROOT=""

log() {
  printf '%s\n' "$*" >&2
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "  FAIL: $CURRENT_TEST - $*"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "  PASS: $CURRENT_TEST"
}

start_test() {
  CURRENT_TEST="$1"
  log "TEST: $CURRENT_TEST"
}

reset_tmp_root() {
  [[ -n "$TEST_TMP_ROOT" ]] && rm -rf "$TEST_TMP_ROOT"
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clean-stale-lanes-test.XXXXXX")"
}

cleanup() {
  [[ -n "$TEST_TMP_ROOT" ]] && rm -rf "$TEST_TMP_ROOT"
}
trap cleanup EXIT

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -b main >/dev/null
  git -C "$repo" config user.name "Harness Test"
  git -C "$repo" config user.email "harness-test@example.com"
  echo "root" > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -m init >/dev/null
}

age_path_hours() {
  local target="$1"
  local hours="$2"
  local seconds=$((hours * 3600))
  perl -e 'my ($age, @paths) = @ARGV; my $t = time - $age; utime $t, $t, @paths;' \
    "$seconds" "$target"
}

age_tree_hours() {
  local root="$1"
  local hours="$2"
  while IFS= read -r path; do
    age_path_hours "$path" "$hours"
  done < <(find "$root" \
    \( -path "$root/.git" -o -path "$root/.git/*" \) -prune -o \
    -type f -print)
}

assert_exists() {
  local path="$1"
  [[ -e "$path" ]] || {
    fail "expected path to exist: $path"
    return 1
  }
}

assert_absent() {
  local path="$1"
  [[ ! -e "$path" ]] || {
    fail "expected path to be absent: $path"
    return 1
  }
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  grep -Fq -- "$needle" <<<"$haystack" || {
    fail "expected output to contain: $needle"
    return 1
  }
}

run_cleanup() {
  local cwd="$1"
  local common_root="$2"
  shift 2
  (
    cd "$cwd"
    env _HARNESS_INTERNAL_TEST_ONLY_CLEAN_LANES_COMMON_ROOT="$common_root" \
      "$SCRIPT" "$@"
  )
}

scenario_dry_run_reports_lane_and_worktree_status() {
  start_test "dry-run classifies special lanes, named lanes, and stale worktrees"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local current_worktree="$TEST_TMP_ROOT/current"
  local stale_worktree="$TEST_TMP_ROOT/stale"
  local output=""

  make_repo "$repo"
  git -C "$repo" worktree add -b current "$current_worktree" >/dev/null
  git -C "$repo" worktree add -b stale "$stale_worktree" >/dev/null

  mkdir -p "$repo/xcode-derived/Build"
  mkdir -p "$repo/xcode-derived-lanes/recent-swift/Build"
  mkdir -p "$repo/xcode-derived-lanes/recent-rust/cargo-target/debug"
  mkdir -p "$repo/xcode-derived-lanes/stale-lane/Build"
  mkdir -p "$repo/xcode-derived-e2e/Build"
  echo "recent" > "$repo/xcode-derived-lanes/recent-swift/Build/Foo.swiftmodule"
  echo "recent" > "$repo/xcode-derived-lanes/recent-rust/cargo-target/debug/harness"
  echo "stale" > "$repo/xcode-derived-lanes/stale-lane/Build/Foo.o"
  echo "stale" > "$repo/xcode-derived-e2e/Build/Foo.dia"
  echo "default" > "$repo/xcode-derived/Build/Keep.o"

  age_tree_hours "$stale_worktree" 5
  age_tree_hours "$repo/xcode-derived-lanes/stale-lane" 5
  age_tree_hours "$repo/xcode-derived-e2e" 5

  output="$(run_cleanup "$current_worktree" "$repo" --dry-run --hours 2 --worktree-hours 2)"

  assert_contains "$output" "keep (active ) recent-swift"
  assert_contains "$output" "keep (active ) recent-rust"
  assert_contains "$output" "drop (dry-run) stale-lane"
  assert_contains "$output" "drop (dry-run) e2e"
  assert_contains "$output" "keep (current) current"
  assert_contains "$output" "drop (dry-run) stale"
  assert_exists "$repo/xcode-derived-lanes/stale-lane"
  assert_exists "$repo/xcode-derived-e2e"
  assert_exists "$stale_worktree"
  pass
}

scenario_apply_cleans_stale_lane_and_worktree() {
  start_test "apply removes stale lane roots and stale linked worktrees but keeps default and current"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local current_worktree="$TEST_TMP_ROOT/current"
  local stale_worktree="$TEST_TMP_ROOT/stale"

  make_repo "$repo"
  git -C "$repo" worktree add -b current "$current_worktree" >/dev/null
  git -C "$repo" worktree add -b stale "$stale_worktree" >/dev/null

  mkdir -p "$repo/xcode-derived/Build"
  mkdir -p "$repo/xcode-derived-lanes/keep-rust/cargo-target/debug"
  mkdir -p "$repo/xcode-derived-lanes/drop-me/Build"
  mkdir -p "$repo/xcode-derived-instruments/Build"
  echo "default" > "$repo/xcode-derived/Build/Main.swiftmodule"
  echo "recent" > "$repo/xcode-derived-lanes/keep-rust/cargo-target/debug/harness"
  echo "stale" > "$repo/xcode-derived-lanes/drop-me/Build/Foo.swiftmodule"
  echo "stale" > "$repo/xcode-derived-instruments/Build/Foo.o"

  age_tree_hours "$stale_worktree" 5
  age_tree_hours "$repo/xcode-derived-lanes/drop-me" 5
  age_tree_hours "$repo/xcode-derived-instruments" 5

  run_cleanup "$current_worktree" "$repo" --hours 2 --worktree-hours 2 >/dev/null

  assert_exists "$repo/xcode-derived"
  assert_exists "$repo/xcode-derived-lanes/keep-rust"
  assert_absent "$repo/xcode-derived-lanes/drop-me"
  assert_absent "$repo/xcode-derived-instruments"
  assert_exists "$current_worktree"
  assert_absent "$stale_worktree"
  pass
}

scenario_worktrees_default_to_longer_window_than_lanes() {
  start_test "default worktree window stays longer than lane window"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local current_worktree="$TEST_TMP_ROOT/current"
  local sibling_worktree="$TEST_TMP_ROOT/sibling"
  local stale_soon_lane="$TEST_TMP_ROOT/repo/xcode-derived-lanes/drop-after-4h"
  local output=""

  make_repo "$repo"
  git -C "$repo" worktree add -b current "$current_worktree" >/dev/null
  git -C "$repo" worktree add -b sibling "$sibling_worktree" >/dev/null

  mkdir -p "$stale_soon_lane/Build"
  echo "stale lane" > "$stale_soon_lane/Build/Foo.swiftmodule"
  age_tree_hours "$stale_soon_lane" 4
  age_tree_hours "$current_worktree" 4
  age_tree_hours "$sibling_worktree" 4

  output="$(run_cleanup "$current_worktree" "$repo" --dry-run)"

  assert_contains "$output" "drop (dry-run) drop-after-4h"
  assert_contains "$output" "keep (current) current"
  assert_contains "$output" "keep (active ) sibling"
  assert_exists "$stale_soon_lane"
  assert_exists "$current_worktree"
  assert_exists "$sibling_worktree"
  pass
}

scenario_dry_run_reports_lane_and_worktree_status
scenario_apply_cleans_stale_lane_and_worktree
scenario_worktrees_default_to_longer_window_than_lanes

log "clean-stale-lanes tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
