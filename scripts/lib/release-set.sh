#!/usr/bin/env bash

# Canonical release inventory shared by the build coordinator, installer, and
# their regression tests. Keep binary and build-leaf entries positionally
# aligned when adding or removing a release executable.
# shellcheck disable=SC2034
HARNESS_RELEASE_BINARIES=(
  harness
  harness-daemon
)
# shellcheck disable=SC2034
HARNESS_RELEASE_BUILD_LEAVES=(
  harness
  daemon
)
# shellcheck disable=SC2034
HARNESS_RELEASE_INACTIVE_BINARIES=()

harness_release_host_os="${HARNESS_RELEASE_HOST_OS:-$(command uname -s)}"
case "$harness_release_host_os" in
  Linux)
    HARNESS_RELEASE_BINARIES+=(harness-systemd)
    HARNESS_RELEASE_BUILD_LEAVES+=(systemd)
    ;;
  Darwin)
    HARNESS_RELEASE_INACTIVE_BINARIES=(harness-systemd)
    ;;
  *)
    printf 'unsupported release build host OS: %s\n' "$harness_release_host_os" >&2
    exit 2
    ;;
esac

HARNESS_RELEASE_BINARIES+=(
  harness-bridge
  harness-mcp
  harness-hook
  harness-codex-acp
  harness-openrouter-agent
)
HARNESS_RELEASE_BUILD_LEAVES+=(
  bridge
  mcp
  hook
  codex
  openrouter
)
unset harness_release_host_os

# shellcheck disable=SC2034
HARNESS_RELEASE_ALL_BINARIES=("${HARNESS_RELEASE_BINARIES[@]}" aff)
# shellcheck disable=SC2034
HARNESS_RELEASE_ALL_BUILD_LEAVES=("${HARNESS_RELEASE_BUILD_LEAVES[@]}" aff)

release_probe_identity() {
  case "$1" in
    harness-codex-acp|harness-openrouter-agent)
      printf '%s\n' "$1"
      ;;
    *)
      return 1
      ;;
  esac
}

release_normalize_target_dir() {
  local target_dir="$1"
  command mkdir -p "$target_dir"
  CDPATH='' command cd -- "$target_dir" && command pwd -P
}

release_pipeline_process_start_marker() {
  local pid="$1"
  LC_ALL=C command ps -p "$pid" -o lstart= 2>/dev/null \
    | command awk '{$1=$1; print; exit}'
}

release_pipeline_lock_age_seconds() {
  local lock_dir="$1" modified now
  if modified="$(command stat -f '%m' "$lock_dir" 2>/dev/null)"; then
    :
  else
    modified="$(command stat -c '%Y' "$lock_dir" 2>/dev/null || true)"
  fi
  now="$(date +%s)"
  if [[ "$modified" =~ ^[0-9]+$ ]] && (( now >= modified )); then
    printf '%s\n' "$((now - modified))"
  else
    printf '0\n'
  fi
}

release_pipeline_lock_owner_is_live() {
  local owner="$1" owner_token owner_pid owner_start live_start
  owner_token="${owner%%|*}"
  owner_pid="${owner_token%%-*}"
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  command kill -0 "$owner_pid" 2>/dev/null || return 1

  if [[ "$owner" != *'|'* ]]; then
    return 0
  fi
  owner_start="${owner#*|}"
  live_start="$(release_pipeline_process_start_marker "$owner_pid")"
  [[ -n "$owner_start" && -n "$live_start" && "$owner_start" == "$live_start" ]]
}

RELEASE_PIPELINE_LOCK_HELD=0
RELEASE_PIPELINE_LOCK_PATH=""
RELEASE_PIPELINE_LOCK_OWNER_RECORD=""
RELEASE_PIPELINE_LOCK_PARTICIPANT_PATH=""

release_pipeline_lock_has_live_participant() {
  local lock_dir="$1" path participant
  [[ -d "$lock_dir/participants" ]] || return 1
  for path in "$lock_dir"/participants/*; do
    [[ -f "$path" ]] || continue
    participant="$(command cat "$path" 2>/dev/null || true)"
    if [[ -n "$participant" ]] \
      && release_pipeline_lock_owner_is_live "$participant"; then
      return 0
    fi
  done
  return 1
}

release_pipeline_lock_register_participant() {
  local lock_dir="$1" token participant_tmp
  token="$$-$(date +%s)-${RANDOM:-0}"
  command mkdir -p "$lock_dir/participants"
  RELEASE_PIPELINE_LOCK_PARTICIPANT_PATH="$lock_dir/participants/$token"
  participant_tmp="$lock_dir/participants/.participant-$token"
  printf '%s|%s\n' "$token" \
    "$(release_pipeline_process_start_marker "$$")" >"$participant_tmp"
  command mv "$participant_tmp" "$RELEASE_PIPELINE_LOCK_PARTICIPANT_PATH"
}

release_pipeline_lock_acquire() {
  local target_dir="$1" owner stale_lock age owner_tmp
  local attempts=0
  local max_attempts="${HARNESS_RELEASE_PIPELINE_LOCK_ATTEMPTS:-1200}"
  local ownerless_stale_seconds="${HARNESS_RELEASE_PIPELINE_OWNERLESS_LOCK_STALE_SECONDS:-30}"
  local lock_token
  local lock_dir="${HARNESS_RELEASE_PIPELINE_LOCK_DIR:-$target_dir/.release-pipeline.lock}"

  lock_token="$$-$(date +%s)-${RANDOM:-0}"

  if [[ ! "$max_attempts" =~ ^[0-9]+$ ]] || (( max_attempts < 1 )); then
    printf 'HARNESS_RELEASE_PIPELINE_LOCK_ATTEMPTS must be a positive integer\n' >&2
    return 2
  fi
  if [[ ! "$ownerless_stale_seconds" =~ ^[0-9]+$ ]]; then
    printf 'HARNESS_RELEASE_PIPELINE_OWNERLESS_LOCK_STALE_SECONDS must be non-negative\n' >&2
    return 2
  fi

  RELEASE_PIPELINE_LOCK_PATH="$lock_dir"
  if [[ -n "${HARNESS_RELEASE_PIPELINE_LOCK_OWNER_RECORD:-}" ]] \
    && [[ "$(command cat "$lock_dir/owner" 2>/dev/null || true)" \
      == "$HARNESS_RELEASE_PIPELINE_LOCK_OWNER_RECORD" ]] \
    && release_pipeline_lock_owner_is_live \
      "$HARNESS_RELEASE_PIPELINE_LOCK_OWNER_RECORD"; then
    RELEASE_PIPELINE_LOCK_OWNER_RECORD="$HARNESS_RELEASE_PIPELINE_LOCK_OWNER_RECORD"
    release_pipeline_lock_register_participant "$lock_dir"
    if [[ "$(command cat "$lock_dir/owner" 2>/dev/null || true)" \
      == "$HARNESS_RELEASE_PIPELINE_LOCK_OWNER_RECORD" ]]; then
      return 0
    fi
    command rm -f "$RELEASE_PIPELINE_LOCK_PARTICIPANT_PATH"
    RELEASE_PIPELINE_LOCK_PARTICIPANT_PATH=""
  fi

  unset HARNESS_RELEASE_PIPELINE_LOCK_OWNER_RECORD
  command mkdir -p "$(dirname -- "$lock_dir")"
  while ! command mkdir "$lock_dir" 2>/dev/null; do
    owner="$(command cat "$lock_dir/owner" 2>/dev/null || true)"
    if { [[ -n "$owner" ]] && release_pipeline_lock_owner_is_live "$owner"; } \
      || release_pipeline_lock_has_live_participant "$lock_dir"; then
      attempts=$((attempts + 1))
      if (( attempts >= max_attempts )); then
        printf 'timed out waiting for release pipeline lock at %s\n' \
          "$lock_dir" >&2
        return 1
      fi
      sleep 0.1
      continue
    fi

    age="$(release_pipeline_lock_age_seconds "$lock_dir")"
    if [[ -n "$owner" ]] || (( age >= ownerless_stale_seconds )); then
      stale_lock="${lock_dir}.stale-${lock_token}-${attempts}"
      if command mv "$lock_dir" "$stale_lock" 2>/dev/null; then
        command rm -rf "$stale_lock"
      fi
      continue
    fi

    attempts=$((attempts + 1))
    if (( attempts >= max_attempts )); then
      printf 'timed out waiting for release pipeline owner at %s\n' \
        "$lock_dir" >&2
      return 1
    fi
    sleep 0.1
  done

  RELEASE_PIPELINE_LOCK_OWNER_RECORD="$lock_token|$(release_pipeline_process_start_marker "$$")"
  owner_tmp="$lock_dir/.owner-${lock_token}"
  printf '%s\n' "$RELEASE_PIPELINE_LOCK_OWNER_RECORD" >"$owner_tmp"
  command mv "$owner_tmp" "$lock_dir/owner"
  RELEASE_PIPELINE_LOCK_HELD=1
  export HARNESS_RELEASE_PIPELINE_LOCK_DIR="$lock_dir"
  export HARNESS_RELEASE_PIPELINE_LOCK_OWNER_RECORD="$RELEASE_PIPELINE_LOCK_OWNER_RECORD"
}

release_pipeline_lock_release() {
  local owner=""
  if [[ -n "$RELEASE_PIPELINE_LOCK_PARTICIPANT_PATH" ]]; then
    command rm -f "$RELEASE_PIPELINE_LOCK_PARTICIPANT_PATH"
    RELEASE_PIPELINE_LOCK_PARTICIPANT_PATH=""
  fi
  (( RELEASE_PIPELINE_LOCK_HELD == 1 )) || return 0
  if release_pipeline_lock_has_live_participant "$RELEASE_PIPELINE_LOCK_PATH"; then
    RELEASE_PIPELINE_LOCK_HELD=0
    return 0
  fi
  owner="$(command cat "$RELEASE_PIPELINE_LOCK_PATH/owner" 2>/dev/null || true)"
  if [[ "$owner" == "$RELEASE_PIPELINE_LOCK_OWNER_RECORD" ]]; then
    command rm -rf "$RELEASE_PIPELINE_LOCK_PATH"
  fi
  RELEASE_PIPELINE_LOCK_HELD=0
}
