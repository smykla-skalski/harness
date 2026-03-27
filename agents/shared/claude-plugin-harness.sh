#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "${script_dir}/../../.." && pwd)

if [ -x "${repo_root}/target/debug/harness" ]; then
  exec "${repo_root}/target/debug/harness" "$@"
fi

if command -v harness >/dev/null 2>&1; then
  exec "$(command -v harness)" "$@"
fi

echo "harness: unable to resolve a current harness binary" >&2
exit 1
