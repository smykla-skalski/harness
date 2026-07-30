#!/usr/bin/env bash
set -euo pipefail

known_groups="harness-lib supporting-crates agents task-board systemd daemon daemon-bin"
total_groups=$(printf '%s' "$known_groups" | wc -w | tr -d ' ')

# HARNESS_SKIP_UNIT_GROUPS: comma-separated group names to skip
#   (e.g. "systemd,agents").
# HARNESS_ONLY_UNIT_GROUP:  run only the given group name (e.g. "daemon").
#   Takes precedence over HARNESS_SKIP_UNIT_GROUPS.
# Extra CLI arguments (e.g. -E 'test(=path::to::test)') arrive here as real
# positional parameters, so forwarding them via "$@" to every package group
# keeps each token's boundaries and quoting intact without re-parsing.

validate_names() {
  local label="$1" raw="$2"
  local trimmed found t k
  local save_ifs="$IFS"
  local restore_f=0
  if [[ $- != *f* ]]; then
    restore_f=1
    set -f
  fi
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
      (( restore_f )) && set +f
      printf 'test:unit: unknown group name in %s: %q\n' "$label" "$trimmed" >&2
      printf '  known groups: %s\n' "$known_groups" >&2
      return 1
    fi
  done
  IFS="$save_ifs"
  (( restore_f )) && set +f
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
    local restore_f=0
    if [[ $- != *f* ]]; then
      restore_f=1
      set -f
    fi
    local IFS=','
    for s in $skip_list; do
      local t="${s#"${s%%[![:space:]]*}"}"
      t="${t%"${t##*[![:space:]]}"}"
      [[ -n "$t" ]] || continue
      if [[ "$t" == "$name" ]]; then
        (( restore_f )) && set +f
        return 1
      fi
    done
    (( restore_f )) && set +f
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

# harness-panel's build script shells out to npm to produce the assets it embeds;
# the unit-test gate exercises the Rust side only, so it gets the placeholder
# bundle instead of a frontend build on every run.
run_group 2 supporting-crates "supporting workspace crates" \
  env HARNESS_PANEL_SKIP_FRONTEND_BUILD=1 ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-acme-dns -p harness-command -p harness-daemon-acp-probe -p harness-daemon-cli -p harness-daemon-client -p harness-daemon-codex -p harness-daemon-discovery -p harness-daemon-launchd -p harness-daemon-provider-credentials -p harness-daemon-remote-cli -p harness-daemon-root -p harness-daemon-snapshot -p harness-daemon-state -p harness-daemon-watch -p harness-db-schema -p harness-feature-flags -p harness-hooks -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-policy-graph-store -p harness-protocol -p harness-remote-trust -p harness-reviews -p harness-run -p harness-sybra -p harness-systemd-protocol -p harness-task-board -p harness-task-board-codex-requests -p harness-task-board-git-runtime -p harness-task-board-provider-sync -p harness-task-board-workflow-execution -p harness-task-board-remote-viewer -p harness-telemetry -p harness-testkit -p harness-timeline -p harness-voice -p harness-workspace "$@"

# Own invocation: `acp` only compiles with `bridge-runtime`, which the rest of
# the supporting group above has no reason to build.
run_group 3 agents "harness-agents (bridge-runtime feature)" \
  ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-agents --lib --features bridge-runtime "$@"

# Extra invocation, on top of harness-task-board's own default-feature run above:
# `policy_runtime`'s tests live behind `daemon-runtime`, which the rest of the
# supporting group has no reason to build.
run_group 4 task-board "harness-task-board (daemon-runtime feature)" \
  ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-task-board --lib --features daemon-runtime "$@"

# Linux-only guard: the real run-linux-only.sh skips on other hosts; the test
# stand-in passes through unconditionally so filtering is validated everywhere.
run_group 5 systemd "Linux systemd crate" \
  ./scripts/run-linux-only.sh ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd "$@"

# Own invocation: harness-daemon runs its own unit tests directly (`--lib`),
# no longer mirrored through root's own test build.
run_group 6 daemon "harness-daemon (own lib)" \
  ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib "$@"

# Separate invocation: nextest's target-type flags (`--lib`) apply to every
# `-p` package in one invocation, not just the one they're written next to.
# harness-daemon-bin has no lib target (its `[[bin]]` moved in #1230), so
# combining it with harness-daemon's `--lib` would silently drop its tests.
run_group 7 daemon-bin "harness-daemon-bin (binary unit and integration tests)" \
  ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon-bin "$@"
