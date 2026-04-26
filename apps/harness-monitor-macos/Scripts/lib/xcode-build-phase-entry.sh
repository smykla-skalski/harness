#!/bin/sh
set -eu

unset SWIFT_DEBUG_INFORMATION_FORMAT
unset SWIFT_DEBUG_INFORMATION_VERSION

if [ "$#" -eq 0 ]; then
  echo "xcode-build-phase-entry.sh requires a target script" >&2
  exit 64
fi

target_script="$1"
shift
/bin/bash "$target_script" "$@"
