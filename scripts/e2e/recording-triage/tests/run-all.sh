#!/usr/bin/env bash
set -euo pipefail

# Run the recording-triage test matrix for this host.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
host_os="$(uname -s)"
portable_tests=(
  test_assert_launch_args.sh
  test_assert_recording.sh
  test_build_fixture.sh
  test_e2e_copy_preserves_mtime.sh
  test_extract_keyframes.sh
)
macos_tests=(
  test_act_timing.sh
  test_assert_act_identifiers.sh
  test_auto_keyframes.sh
  test_compare_keyframes.sh
  test_compare_layout.sh
  test_emit_checklist.sh
  test_frame_gaps.sh
  test_run_all.sh
)
selected_tests=("${portable_tests[@]}")
case "$host_os" in
  Darwin)
    selected_tests+=("${macos_tests[@]}")
    ;;
  Linux)
    printf 'skipping %d macOS recording-triage tests on Linux\n' "${#macos_tests[@]}"
    ;;
  *)
    printf 'unsupported recording-triage test host OS: %s\n' "$host_os" >&2
    exit 1
    ;;
esac

failures=0
ran=0
for test_name in "${selected_tests[@]}"; do
  test_path="$SCRIPT_DIR/$test_name"
  ran=$((ran + 1))
  printf '== running %s\n' "$test_name"
  if ! "$test_path"; then
    failures=$((failures + 1))
    printf '!! failed: %s\n' "$test_name" >&2
  fi
done

if (( ran == 0 )); then
  printf 'no recording-triage tests selected for %s\n' "$host_os" >&2
  exit 1
fi

if (( failures > 0 )); then
  printf '%d recording-triage test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all %d recording-triage tests passed\n' "$ran"
