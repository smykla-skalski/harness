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

# Mirrors cargo-local.sh's target_segment. scenario_dev_segment_derivation_
# matches_cargo_local pins it against the real script so a drift in either
# shows up as a failure instead of a lane nobody reclaims.
dev_segment_for_path() {
  local path="$1" name digest
  name="$(printf '%s' "$(basename -- "$path")" | tr -cs '[:alnum:]._-' '-')"
  digest="$(printf '%s' "$path" | shasum -a 256)"
  printf 'wt-%s-%s\n' "$name" "${digest:0:16}"
}

scenario_dev_lanes_follow_their_worktree() {
  start_test "cargo lanes are kept while their worktree lives and dropped once it does not"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local live_worktree="$TEST_TMP_ROOT/live"
  local output="" live_seg orphan_seg

  make_repo "$repo"
  git -C "$repo" worktree add -b live "$live_worktree" >/dev/null
  live_seg="$(dev_segment_for_path "$(cd "$live_worktree" && pwd -P)")"
  orphan_seg="wt-long-gone-0123456789abcdef"

  mkdir -p "$repo/target/dev/local/debug" \
    "$repo/target/dev/$live_seg/debug" \
    "$repo/target/dev/$orphan_seg/debug"
  echo x > "$repo/target/dev/local/debug/a"
  echo x > "$repo/target/dev/$live_seg/debug/a"
  echo x > "$repo/target/dev/$orphan_seg/debug/a"

  output="$(run_cleanup "$live_worktree" "$repo" --dry-run)"

  assert_contains "$output" "keep (main   ) local"
  assert_contains "$output" "$live_seg"
  assert_contains "$output" "drop (dry-run) $orphan_seg"
  assert_exists "$repo/target/dev/$orphan_seg"

  output="$(run_cleanup "$live_worktree" "$repo")"
  assert_absent "$repo/target/dev/$orphan_seg"
  assert_exists "$repo/target/dev/$live_seg"
  assert_exists "$repo/target/dev/local"
  pass
}

scenario_leased_dev_lane_survives_even_when_orphaned() {
  start_test "a cargo lane with a live build lease is kept even with no worktree left"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local seg="wt-leased-fedcba9876543210"
  local holder_pid=""

  make_repo "$repo"
  mkdir -p "$repo/target/dev/$seg/debug" "$repo/target/.cargo-local/leases"
  echo x > "$repo/target/dev/$seg/debug/a"

  sleep 120 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$repo/target/.cargo-local/leases/$seg-$holder_pid"

  run_cleanup "$repo" "$repo" >/dev/null
  assert_exists "$repo/target/dev/$seg"

  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  rm -f "$repo/target/.cargo-local/leases/$seg-$holder_pid"

  run_cleanup "$repo" "$repo" >/dev/null
  assert_absent "$repo/target/dev/$seg"
  pass
}

scenario_corrupt_lease_does_not_pin_a_lane() {
  start_test "a lease holding 0 or junk is corrupt, not a live build"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local zero_seg="wt-zero-00000000000000aa"
  local junk_seg="wt-junk-00000000000000bb"

  make_repo "$repo"
  mkdir -p "$repo/target/dev/$zero_seg" "$repo/target/dev/$junk_seg" \
    "$repo/target/.cargo-local/leases"
  echo x > "$repo/target/dev/$zero_seg/a"
  echo x > "$repo/target/dev/$junk_seg/a"
  # kill -0 0 succeeds against the caller's own process group, so an unguarded
  # numeric check would read this as a running build and keep the lane for good.
  printf '0\n' > "$repo/target/.cargo-local/leases/$zero_seg-0"
  printf 'not-a-pid\n' > "$repo/target/.cargo-local/leases/$junk_seg-not-a-pid"

  run_cleanup "$repo" "$repo" >/dev/null
  assert_absent "$repo/target/dev/$zero_seg"
  assert_absent "$repo/target/dev/$junk_seg"
  pass
}

scenario_dev_segment_derivation_matches_cargo_local() {
  start_test "the lane segment this script derives matches cargo-local.sh"
  local printed derived
  printed="$(basename -- "$(env -u CARGO_TARGET_DIR -u HARNESS_CARGO_TARGET_DIR \
    "$ROOT/scripts/cargo-local.sh" --print-target-dir)")"
  derived="$(dev_segment_for_path "$(cd "$ROOT" && pwd -P)")"

  if [[ "$printed" == "local" ]]; then
    pass
    return 0
  fi
  if [[ "$printed" == "$derived" ]]; then
    pass
  else
    fail "segment derivation drifted: cargo-local=$printed test=$derived"
  fi
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
scenario_dev_lanes_follow_their_worktree
scenario_leased_dev_lane_survives_even_when_orphaned
scenario_corrupt_lease_does_not_pin_a_lane
scenario_dev_segment_derivation_matches_cargo_local

log "clean-stale-lanes tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
