#!/bin/bash

swift_package_release_binary_path() {
  local package_dir="$1"
  local binary_name="$2"
  printf '%s/.build/release/%s\n' "$package_dir" "$binary_name"
}

swift_package_source_state_path() {
  local package_dir="$1"
  local binary_name="$2"
  printf '%s/.build/release/.%s.freshness-state\n' "$package_dir" "$binary_name"
}

swift_package_source_fingerprint() {
  local package_dir="$1"
  local digest_line path rel_path file_digest

  digest_line="$(
    while IFS= read -r path; do
      rel_path="${path#$package_dir/}"
      file_digest="$(
        /usr/bin/shasum -a 256 "$path" \
          | /usr/bin/awk '{print $1}'
      )"
      printf '%s %s\n' "$rel_path" "$file_digest"
    done < <(
      /usr/bin/find "$package_dir" \
        \( \
          -path "$package_dir/.build" -o \
          -path "$package_dir/.build/*" -o \
          -path "$package_dir/.swiftpm" -o \
          -path "$package_dir/.swiftpm/*" -o \
          -path "$package_dir/.git" -o \
          -path "$package_dir/.git/*" \
        \) -prune -o \
        -type f -print \
        | /usr/bin/sort
    ) \
      | /usr/bin/shasum -a 256 \
      | /usr/bin/awk '{print $1}'
  )"

  printf '%s\n' "$digest_line"
}

swift_package_source_state_matches() {
  local state_path="$1"
  local expected_fingerprint="$2"
  local recorded_fingerprint

  if [[ ! -f "$state_path" ]]; then
    return 1
  fi

  recorded_fingerprint="$(/bin/cat "$state_path" 2>/dev/null || true)"
  [[ "$recorded_fingerprint" == "$expected_fingerprint" ]]
}

swift_package_write_source_state() {
  local state_path="$1"
  local fingerprint="$2"
  local state_dir temp_state

  state_dir="$(/usr/bin/dirname "$state_path")"
  /bin/mkdir -p "$state_dir"
  temp_state="${state_path}.tmp.$$"
  printf '%s\n' "$fingerprint" > "$temp_state"
  /bin/mv "$temp_state" "$state_path"
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
  local binary_path state_path source_fingerprint needs_build=0

  binary_path="$(swift_package_release_binary_path "$package_dir" "$binary_name")"
  state_path="$(swift_package_source_state_path "$package_dir" "$binary_name")"
  source_fingerprint="$(swift_package_source_fingerprint "$package_dir")"

  if [[ ! -x "$binary_path" ]]; then
    needs_build=1
  elif ! swift_package_source_state_matches "$state_path" "$source_fingerprint"; then
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

  source_fingerprint="$(swift_package_source_fingerprint "$package_dir")"
  swift_package_write_source_state "$state_path" "$source_fingerprint"

  printf '%s\n' "$binary_path"
}
