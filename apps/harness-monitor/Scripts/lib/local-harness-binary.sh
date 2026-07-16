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

build_local_acp_adapters() {
  local checkout_root="$1"
  local adapter

  for adapter in harness-codex-acp harness-openrouter-agent; do
    "$checkout_root/scripts/cargo-local.sh" build \
      --quiet \
      --manifest-path "$checkout_root/crates/$adapter/Cargo.toml" \
      --bin "$adapter" \
      >/dev/null
  done
}

resolve_local_harness_binary() {
  local checkout_root="$1"
  local override_env_name="$2"
  local binary_name="${3:-harness}"
  local target_dir binary_path

  binary_path="${!override_env_name:-}"
  if [[ -n "$binary_path" ]]; then
    if [[ ! -x "$binary_path" ]]; then
      printf 'configured %s binary is not executable: %s\n' "$binary_name" "$binary_path" >&2
      exit 1
    fi
    printf '%s\n' "$binary_path"
    return 0
  fi

  target_dir="$(resolve_local_cargo_target_dir "$checkout_root")"
  if [[ "$binary_name" == "harness-daemon" || "$binary_name" == "harness-bridge" ]]; then
    build_local_acp_adapters "$checkout_root"
  fi
  "$checkout_root/scripts/cargo-local.sh" build \
    --quiet \
    --package "$binary_name" \
    --bin "$binary_name" \
    >/dev/null
  binary_path="$target_dir/debug/$binary_name"
  if [[ ! -x "$binary_path" ]]; then
    printf 'failed to resolve built local %s binary at %s\n' "$binary_name" "$binary_path" >&2
    exit 1
  fi

  printf '%s\n' "$binary_path"
}
