#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'error: local-harness-binary.sh must be sourced, not executed directly\n' >&2
  exit 1
fi

resolve_local_cargo_target_dir() {
  local checkout_root="$1"
  local target_dir

  if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    printf '%s\n' "$CARGO_TARGET_DIR"
    return 0
  fi

  target_dir="$(
    "$checkout_root/scripts/cargo-local.sh" --print-env \
      | command awk -F= '/^CARGO_TARGET_DIR=/{print $2}'
  )"
  if [[ -z "$target_dir" ]]; then
    printf 'failed to resolve CARGO_TARGET_DIR via scripts/cargo-local.sh --print-env\n' >&2
    exit 1
  fi

  printf '%s\n' "$target_dir"
}

resolve_local_harness_binary() {
  local checkout_root="$1"
  local override_env_name="$2"
  local target_dir binary_path

  binary_path="${!override_env_name:-}"
  if [[ -n "$binary_path" ]]; then
    if [[ ! -x "$binary_path" ]]; then
      printf 'configured harness binary is not executable: %s\n' "$binary_path" >&2
      exit 1
    fi
    printf '%s\n' "$binary_path"
    return 0
  fi

  target_dir="$(resolve_local_cargo_target_dir "$checkout_root")"
  "$checkout_root/scripts/cargo-local.sh" build --quiet --bin harness >/dev/null
  binary_path="$target_dir/debug/harness"
  if [[ ! -x "$binary_path" ]]; then
    printf 'failed to resolve built local harness binary at %s\n' "$binary_path" >&2
    exit 1
  fi

  printf '%s\n' "$binary_path"
}
