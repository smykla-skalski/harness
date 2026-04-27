#!/bin/sh
set -eu

if [ "${CLAUDE_PROJECT_DIR:-}" ]; then
  candidate="${CLAUDE_PROJECT_DIR}/.claude/plugins/suite/harness"
  if [ -x "${candidate}" ]; then
    current=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
    if [ "$(cd -- "$(dirname -- "${candidate}")" && pwd)/$(basename -- "${candidate}")" != "${current}" ]; then
      exec "${candidate}" "$@"
    fi
  fi
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
current="${script_dir}/$(basename -- "$0")"
repo_root=$(CDPATH= cd -- "${script_dir}/../../.." && pwd)

repo_version() {
  command awk '
    $0 == "[package]" { in_package = 1; next }
    /^\[/ { if (in_package) exit }
    in_package && $1 == "version" {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "${repo_root}/Cargo.toml"
}

binary_version() {
  "$1" --version 2>/dev/null | command awk 'NR == 1 { print $2 }'
}

if [ -x "${repo_root}/target/debug/harness" ]; then
  exec "${repo_root}/target/debug/harness" "$@"
fi

if command -v harness >/dev/null 2>&1; then
  candidate="$(command -v harness)"
  candidate_dir=$(CDPATH= cd -- "$(dirname -- "${candidate}")" && pwd)
  candidate_path="${candidate_dir}/$(basename -- "${candidate}")"
  if [ "${candidate_path}" = "${current}" ]; then
    echo "harness: unable to resolve a current harness binary" >&2
    exit 1
  fi

  expected_version="$(repo_version)"
  actual_version="$(binary_version "${candidate_path}")"
  if [ -n "${expected_version}" ] && [ "${actual_version}" = "${expected_version}" ]; then
    exec "${candidate_path}" "$@"
  fi

  echo "harness: refusing to use ${candidate_path} because version ${actual_version:-unknown} does not match repo version ${expected_version:-unknown}; run \`mise run install\` or build target/debug/harness" >&2
  exit 1
fi

echo "harness: unable to resolve a current harness binary" >&2
exit 1
