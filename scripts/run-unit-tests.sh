#!/usr/bin/env bash
set -euo pipefail

total_groups=7
known_groups="harness-lib supporting-crates agents task-board systemd daemon daemon-bin"

# HARNESS_SKIP_UNIT_GROUPS: comma-separated group names to skip
#   (e.g. "systemd,agents").
# HARNESS_ONLY_UNIT_GROUP:  run only the given group name (e.g. "daemon").
#   Takes precedence over HARNESS_SKIP_UNIT_GROUPS.
# Extra CLI arguments (e.g. -E 'test(=path::to::test)') arrive here as real
# positional parameters, so forwarding them via "$@" to every package group
# keeps each token's boundaries and quoting intact without re-parsing.

validate_names() {
  local label="$1" raw="$2"
  local trimmed found
  local save_ifs="$IFS"
  set -f
  IFS=','
  for t in $raw; do
    trimmed="${t#"${t%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [[ -z "$trimmed" ]]; then
      continue
    fi
    found=0
    IFS=$' \t\n'
    for k in $known_groups; do
      [[ "$trimmed" == "$k" ]] && { found=1; break; }
    done
    IFS=','
    if (( ! found )); then
      IFS="$save_ifs"
      printf 'test:unit: unknown group name in %s: %q\n' "$label" "$trimmed" >&2
      printf '  known groups: %s\n' "$known_groups" >&2
      return 1
    fi
  done
  IFS="$save_ifs"
  return 0
}

should_run() {
  local name="$1"
  local only="${HARNESS_ONLY_UNIT_GROUP:-}"
  if [[ -n "$only" ]]; then
    if [[ "$only" == *","* ]]; then
      printf 'test:unit: HARNESS_ONLY_UNIT_GROUP must be a single group name, got: %q\n' "$only" >&2
      exit 1
    fi
    validate_names HARNESS_ONLY_UNIT_GROUP "$only" || exit 1
    local only_trimmed="${only#"${only%%[![:space:]]*}"}"
    only_trimmed="${only_trimmed%"${only_trimmed##*[![:space:]]}"}"
    [[ "$only_trimmed" == "$name" ]] && return 0
    return 1
  fi
  local skip_list="${HARNESS_SKIP_UNIT_GROUPS:-}"
  if [[ -n "$skip_list" ]]; then
    validate_names HARNESS_SKIP_UNIT_GROUPS "$skip_list" || exit 1
    set -f
    local IFS=','
    for s in $skip_list; do
      local t="${s#"${s%%[![:space:]]*}"}"
      t="${t%"${t##*[![:space:]]}"}"
      [[ -n "$t" ]] || continue
      [[ "$t" == "$name" ]] && return 1
    done
  fi
  return 0
}

run_group() {
  local n="$1" name="$2" desc="$3"; shift 3
  if ! should_run "$name"; then
    printf '==> test:unit %d/%d: %s (skipped)\n' "$n" "$total_groups" "$desc" >&2
    return 0
  fi
  printf '==> test:unit %d/%d: %s\n' "$n" "$total_groups" "$desc" >&2
  "$@"
}

run_group 1 harness-lib "root Harness library" \
  ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime "$@"

run_group 2 supporting-crates "supporting workspace crates" \
  env HARNESS_PANEL_SKIP_FRONTEND_BUILD=1 ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-acme-dns -p harness-command -p harness-daemon-acp-probe -p harness-daemon-cli -p harness-daemon-client -p harness-daemon-discovery -p harness-daemon-launchd -p harness-daemon-provider-credentials -p harness-daemon-root -p harness-daemon-snapshot -p harness-daemon-state -p harness-db-schema -p harness-feature-flags -p harness-hooks -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-policy-graph-store -p harness-protocol -p harness-remote-trust -p harness-reviews -p harness-run -p harness-sybra -p harness-systemd-protocol -p harness-task-board -p harness-task-board-codex-requests -p harness-task-board-provider-sync -p harness-task-board-remote-viewer -p harness-telemetry -p harness-testkit -p harness-timeline -p harness-voice -p harness-workspace "$@"

run_group 3 agents "harness-agents (bridge-runtime feature)" \
  ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-agents --lib --features bridge-runtime "$@"

run_group 4 task-board "harness-task-board (daemon-runtime feature)" \
  ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-task-board --lib --features daemon-runtime "$@"

run_group 5 systemd "Linux systemd crate" \
  ./scripts/run-linux-only.sh ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd "$@"

run_group 6 daemon "harness-daemon (own lib)" \
  ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib "$@"

run_group 7 daemon-bin "harness-daemon-bin (binary unit and integration tests)" \
  ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon-bin "$@"