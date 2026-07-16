#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  printf 'usage: %s COMMAND [ARG ...]\n' "${0##*/}" >&2
  exit 2
fi

host_os="$(uname -s)"
case "$host_os" in
  Linux)
    exec "$@"
    ;;
  Darwin)
    printf 'skipping Linux-only command on macOS\n'
    ;;
  *)
    printf 'error: unsupported host OS for Linux-only command: %s\n' "$host_os" >&2
    exit 1
    ;;
esac
