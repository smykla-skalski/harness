#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

# Resolve sccache by absolute path, not PATH lookup. Cargo bakes this stable
# wrapper path into its fingerprint while the wrapper selects cached or direct
# compilation without changing Cargo's configured rustc wrapper.
#
# `SCCACHE_BIN` is resolved once by cargo-local. Plain Cargo and Xcode builds
# retain fixed Homebrew fallbacks. Versions older than 0.14 are skipped because
# they cannot provide the socket isolation and multi-worktree path normalization
# used by the repository.

sccache_version_supported() {
  local version="${1#v}" major minor patch
  version="${version%%[-+]*}"
  IFS=. read -r major minor patch <<<"$version"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"

  [[ "$major" =~ ^[0-9]+$ ]] \
    && [[ "$minor" =~ ^[0-9]+$ ]] \
    && [[ "$patch" =~ ^[0-9]+$ ]] \
    && (( major > 0 || minor >= 14 ))
}

sccache_candidate_usable() {
  local candidate="$1" output version
  [[ -x "$candidate" ]] || return 1
  output="$("$candidate" --version 2>/dev/null)" || return 1
  version="${output##* }"
  sccache_version_supported "$version"
}

sccache_env_usable() {
  local candidate="$1"
  [[ -x "$candidate" ]] || return 1

  if [[ -n "${SCCACHE_VERSION:-}" ]]; then
    sccache_version_supported "$SCCACHE_VERSION"
  else
    sccache_candidate_usable "$candidate"
  fi
}

sccache_tmpdir() {
  local candidate="${HARNESS_SCCACHE_TMPDIR:-${TMPDIR:-/tmp}}"
  candidate="${candidate%/}"

  if (( ${#candidate} > 60 )) || [[ ! -d "$candidate" ]] || [[ ! -w "$candidate" ]]; then
    candidate="/tmp"
  fi
  [[ -d "$candidate" ]] && [[ -w "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

run_sccache() {
  local binary="$1" temp_dir
  shift

  temp_dir="$(sccache_tmpdir)" || exec "$@"
  TMPDIR="$temp_dir/" exec "$binary" "$@"
}

if [[ "${SCCACHE_BIN+x}" == "x" ]]; then
  if [[ -n "$SCCACHE_BIN" ]] && sccache_env_usable "$SCCACHE_BIN"; then
    run_sccache "$SCCACHE_BIN" "$@"
  fi
  exec "$@"
fi

for sccache_candidate in \
  /opt/homebrew/bin/sccache \
  /usr/local/bin/sccache; do
  if sccache_candidate_usable "$sccache_candidate"; then
    run_sccache "$sccache_candidate" "$@"
  fi
done

exec "$@"
