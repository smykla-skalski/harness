#!/bin/bash

swift_package_release_binary_path() {
  local package_dir="$1"
  local binary_name="$2"
  printf '%s/.build/release/%s\n' "$package_dir" "$binary_name"
}

swift_package_has_newer_sources_than_binary() {
  local package_dir="$1"
  local binary_path="$2"
  local newer_path

  newer_path="$(
    /usr/bin/find "$package_dir" \
      \( \
        -path "$package_dir/.build" -o \
        -path "$package_dir/.build/*" -o \
        -path "$package_dir/.swiftpm" -o \
        -path "$package_dir/.swiftpm/*" \
      \) -prune -o \
      -type f -newer "$binary_path" -print -quit 2>/dev/null
  )"

  [[ -n "$newer_path" ]]
}

swift_package_build_release() {
  local package_dir="$1"

  if declare -F run_with_sanitized_xcode_only_swift_environment >/dev/null 2>&1; then
    run_with_sanitized_xcode_only_swift_environment \
      swift build -c release --package-path "$package_dir"
    return 0
  fi

  swift build -c release --package-path "$package_dir"
}

ensure_swift_package_release_binary_fresh() {
  local package_dir="$1"
  local binary_name="$2"
  local display_name="${3:-$binary_name}"
  local binary_path needs_build=0

  binary_path="$(swift_package_release_binary_path "$package_dir" "$binary_name")"

  if [[ ! -x "$binary_path" ]]; then
    needs_build=1
  elif swift_package_has_newer_sources_than_binary "$package_dir" "$binary_path"; then
    needs_build=1
  fi

  if (( needs_build == 1 )); then
    printf 'Building %s Swift CLI...\n' "$display_name" >&2
    swift_package_build_release "$package_dir" >&2
  fi

  if [[ ! -x "$binary_path" ]]; then
    printf '%s binary missing after build at %s\n' "$display_name" "$binary_path" >&2
    return 1
  fi

  printf '%s\n' "$binary_path"
}
