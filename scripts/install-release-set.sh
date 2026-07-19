#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true
shopt -s nullglob

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/lib/release-set.sh
source "$ROOT/scripts/lib/release-set.sh"

selectors=()
print_mode=""
for arg in "$@"; do
  case "$arg" in
    --print-build-binary|--print-build-codex-acp-binary|--print-build-openrouter-binary)
      if [[ -n "$print_mode" ]]; then
        printf 'only one --print-build-* option may be given\n' >&2
        exit 2
      fi
      print_mode="$arg"
      ;;
    --*)
      printf 'unknown install-release-set option: %s\n' "$arg" >&2
      exit 2
      ;;
    *)
      selectors+=("$arg")
      ;;
  esac
done
(( ${#selectors[@]} > 0 )) || selectors=(all)

requested_all=0
for selector in "${selectors[@]}"; do
  [[ "$selector" == all ]] && requested_all=1
done

if ! release_set_resolve_selectors "${selectors[@]}"; then
  printf 'usage: %s [<selector>...] [--print-build-binary|--print-build-codex-acp-binary|--print-build-openrouter-binary]\n' "${0##*/}" >&2
  printf 'selector: all, harness, aff, or a leaf (harness-cli, daemon, systemd, bridge, mcp, hook, codex, openrouter)\n' >&2
  exit 2
fi

harness_binary_dir="${HARNESS_INSTALL_BINARY_DIR:-${HOME}/.local/bin}"
aff_binary_dir="${AFF_INSTALL_BINARY_DIR:-$harness_binary_dir}"
install_root="${HARNESS_INSTALL_ROOT:-${HOME}/.local/lib/harness}"
release_set_retention="${HARNESS_INSTALL_RETAIN_RELEASE_SETS:-3}"
harness_signing_identity="${HARNESS_INSTALL_SIGNING_IDENTITY:-Developer ID Application: Bartlomiej Smykla (Q498EB36N4)}"
harness_signing_team_id="${HARNESS_INSTALL_SIGNING_TEAM_ID:-Q498EB36N4}"
aff_signing_identity="${AFF_INSTALL_SIGNING_IDENTITY:-$harness_signing_identity}"
harness_skip_codesign="${HARNESS_INSTALL_SKIP_CODESIGN:-0}"
aff_skip_codesign="${AFF_INSTALL_SKIP_CODESIGN:-$harness_skip_codesign}"
[[ "$(uname -s)" != "Darwin" ]] && harness_skip_codesign=1 aff_skip_codesign=1
lock_dir="$install_root/.install.lock"
current_link="$install_root/current"
lock_token="$$-$(date +%s)-${RANDOM:-0}"
lock_held=0
completed=0
current_may_have_changed=0
original_current_target=""
previous_target=""
candidate_stage=""
normalization_stage=""
candidate_dir_created=""
normalization_dir_created=""
created_links=()
entrypoint_backup_paths=()
entrypoint_backup_sources=()
staged_link_paths=()
staged_link_failure_injected=0
shadow_candidates=()
shadow_backup_paths=()
shadow_backup_sources=()

all_binaries=("${HARNESS_RELEASE_ALL_BINARIES[@]}")
selected_binaries=("${RELEASE_SET_SELECTED_BINARIES[@]}")

resolve_target_dir() {
  if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    printf '%s\n' "$CARGO_TARGET_DIR"
    return 0
  fi

  "$ROOT/scripts/cargo-local.sh" --print-env \
    | command awk -F= '/^CARGO_TARGET_DIR=/{print $2}'
}

target_dir="$(resolve_target_dir)"
if [[ -z "$target_dir" ]]; then
  printf 'failed to resolve CARGO_TARGET_DIR\n' >&2
  exit 1
fi
target_dir="$(release_normalize_target_dir "$target_dir")"
export CARGO_TARGET_DIR="$target_dir"

case "$print_mode" in
  "")
    ;;
  --print-build-binary)
    if [[ "${#selected_binaries[@]}" -eq 1 && "${selected_binaries[0]}" == "aff" ]]; then
      printf '%s/release/aff\n' "$target_dir"
    else
      printf '%s/release/harness\n' "$target_dir"
    fi
    exit 0
    ;;
  --print-build-codex-acp-binary)
    printf '%s/release/harness-codex-acp\n' "$target_dir"
    exit 0
    ;;
  --print-build-openrouter-binary)
    printf '%s/release/harness-openrouter-agent\n' "$target_dir"
    exit 0
    ;;
esac

stable_path() {
  local name="$1"
  if [[ "$name" == "aff" ]]; then
    printf '%s/%s\n' "$aff_binary_dir" "$name"
  else
    printf '%s/%s\n' "$harness_binary_dir" "$name"
  fi
}

build_path() {
  printf '%s/release/%s\n' "$target_dir" "$1"
}

binary_version() {
  "$1" --version 2>/dev/null | command awk 'NR == 1 {print $2}'
}

legacy_adapter_probe_is_owned() {
  local name="$1"
  local path="$2"
  local mode
  local probe_output
  local requirement

  case "$name" in
    harness-codex-acp|harness-openrouter-agent)
      ;;
    *)
      return 1
      ;;
  esac

  # The direct-file installer shipped these adapters with a silent successful
  # probe before probes reported an identity. Limit that compatibility path to
  # the read-only regular files published by that installer.
  [[ -f "$path" && ! -L "$path" ]] || return 1
  if mode="$(command stat -f '%Lp' "$path" 2>/dev/null)"; then
    :
  else
    mode="$(command stat -c '%a' "$path" 2>/dev/null || true)"
  fi
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  (( (8#$mode & 0222) == 0 )) || return 1
  probe_output="$("$path" --probe 2>&1)" || return 1
  [[ -z "$probe_output" ]] || return 1
  [[ "$harness_signing_team_id" =~ ^[A-Z0-9]{10}$ ]] || return 1
  command -v codesign >/dev/null 2>&1 || return 1
  requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$harness_signing_team_id\" and identifier \"$name\""
  command codesign --verify --strict -R="$requirement" "$path" \
    >/dev/null 2>&1
}

binary_is_owned() {
  local name="$1"
  local path="$2"
  local reported_name expected_probe
  [[ -x "$path" ]] || return 1

  case "$name" in
    harness-codex-acp|harness-openrouter-agent)
      expected_probe="$(release_probe_identity "$name")"
      reported_name="$("$path" --probe 2>/dev/null)"
      [[ "$reported_name" == "$expected_probe" ]]
      ;;
    harness)
      reported_name="$("$path" --version 2>/dev/null | command awk 'NR == 1 {print $1}')"
      [[ "$reported_name" == "$name" ]] \
        && "$path" --help 2>/dev/null | command grep -Fq 'Harness CLI'
      ;;
    *)
      reported_name="$("$path" --version 2>/dev/null | command awk 'NR == 1 {print $1}')"
      [[ "$reported_name" == "$name" ]]
      ;;
  esac
}

normalization_binary_is_owned() {
  binary_is_owned "$1" "$2" \
    || legacy_adapter_probe_is_owned "$1" "$2"
}

codesign_is_skipped() {
  if [[ "$1" == "aff" ]]; then
    [[ "$aff_skip_codesign" == "1" ]]
  else
    [[ "$harness_skip_codesign" == "1" ]]
  fi
}

signing_identity_for() {
  if [[ "$1" == "aff" ]]; then
    printf '%s\n' "$aff_signing_identity"
  else
    printf '%s\n' "$harness_signing_identity"
  fi
}

atomic_replace_symlink() {
  local target="$1"
  local destination="$2"
  local staged_link="${destination}.next-${lock_token}"
  command mkdir -p "$(dirname -- "$destination")"
  command rm -f "$staged_link"
  staged_link_paths+=("$staged_link")
  command ln -s "$target" "$staged_link"
  if [[ "${HARNESS_INSTALL_TEST_FAIL_WITH_STAGED_LINK:-0}" == "1" ]] \
    && (( staged_link_failure_injected == 0 )); then
    staged_link_failure_injected=1
    printf 'injected staged-link publication failure\n' >&2
    return 94
  fi
  if command mv --help 2>&1 | command grep -q -- '-T'; then
    if ! command mv -Tf "$staged_link" "$destination"; then
      command rm -f "$staged_link"
      return 1
    fi
  else
    if ! command mv -fh "$staged_link" "$destination"; then
      command rm -f "$staged_link"
      return 1
    fi
  fi
}

atomic_restore_backup() {
  local backup="$1"
  local destination="$2"
  [[ -e "$backup" || -L "$backup" ]] || return 0
  if command mv --help 2>&1 | command grep -q -- '-T'; then
    command mv -Tf "$backup" "$destination"
  else
    command mv -fh "$backup" "$destination"
  fi
}

process_start_marker() {
  local pid="$1"
  LC_ALL=C command ps -p "$pid" -o lstart= 2>/dev/null \
    | command awk '{$1=$1; print; exit}'
}

lock_age_seconds() {
  local modified now
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

lock_owner_is_live() {
  local owner="$1"
  local owner_token owner_pid owner_start live_start
  owner_token="${owner%%|*}"
  owner_pid="${owner_token%%-*}"
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  command kill -0 "$owner_pid" 2>/dev/null || return 1

  if [[ "$owner" != *'|'* ]]; then
    return 0
  fi
  owner_start="${owner#*|}"
  live_start="$(process_start_marker "$owner_pid")"
  [[ -n "$owner_start" && -n "$live_start" && "$owner_start" == "$live_start" ]]
}

lock_owner_record="$lock_token|$(process_start_marker "$$")"

release_lock() {
  local owner=""
  (( lock_held == 1 )) || return 0
  owner="$(command cat "$lock_dir/owner" 2>/dev/null || true)"
  if [[ "$owner" == "$lock_owner_record" ]]; then
    command rm -rf "$lock_dir"
  fi
  lock_held=0
}

restore_shadow_backups() {
  local index
  for ((index = ${#shadow_backup_sources[@]} - 1; index >= 0; index--)); do
    if atomic_restore_backup \
      "${shadow_backup_paths[index]}" "${shadow_backup_sources[index]}"; then
      shadow_backup_paths[index]=""
    else
      printf 'warning: failed to restore %s\n' \
        "${shadow_backup_sources[index]}" >&2
    fi
  done
}

restore_entrypoint_backups() {
  local index
  for ((index = ${#entrypoint_backup_sources[@]} - 1; index >= 0; index--)); do
    if atomic_restore_backup \
      "${entrypoint_backup_paths[index]}" "${entrypoint_backup_sources[index]}"; then
      entrypoint_backup_paths[index]=""
    else
      printf 'warning: failed to restore %s\n' \
        "${entrypoint_backup_sources[index]}" >&2
    fi
  done
}

remove_backup_files() {
  local path
  if (( ${#entrypoint_backup_paths[@]} > 0 )); then
    for path in "${entrypoint_backup_paths[@]}"; do
      [[ -n "$path" ]] && command rm -f "$path"
    done
  fi
  if (( ${#shadow_backup_paths[@]} > 0 )); then
    for path in "${shadow_backup_paths[@]}"; do
      [[ -n "$path" ]] && command rm -f "$path"
    done
  fi
}

rollback_install() {
  local path current_restored=1

  restore_shadow_backups
  if (( current_may_have_changed == 1 )); then
    if [[ -n "$original_current_target" ]]; then
      atomic_replace_symlink "$original_current_target" "$current_link" || {
        printf 'warning: failed to roll current back to %s\n' \
          "$original_current_target" >&2
        current_restored=0
      }
    else
      command rm -f "$current_link"
    fi
  fi
  restore_entrypoint_backups
  if (( ${#created_links[@]} > 0 )); then
    for path in "${created_links[@]}"; do
      if [[ -L "$path" ]]; then
        command rm -f "$path"
      fi
    done
  fi
  if (( current_restored == 1 )); then
    [[ -n "$candidate_dir_created" ]] && command rm -rf "$candidate_dir_created"
    [[ -n "$normalization_dir_created" ]] && command rm -rf "$normalization_dir_created"
  fi
}

cleanup_on_exit() {
  local status=$? path
  trap - EXIT INT TERM
  set +e
  if (( status != 0 && completed == 0 )); then
    rollback_install
  fi
  [[ -n "$candidate_stage" ]] && command rm -rf "$candidate_stage"
  [[ -n "$normalization_stage" ]] && command rm -rf "$normalization_stage"
  if (( ${#staged_link_paths[@]} > 0 )); then
    for path in "${staged_link_paths[@]}"; do
      command rm -f "$path"
    done
  fi
  if (( completed == 1 )); then
    remove_backup_files
  fi
  release_lock
  release_pipeline_lock_release
  exit "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_lock() {
  local owner owner_pid stale_lock age
  local attempts=0
  local max_attempts="${HARNESS_INSTALL_LOCK_ATTEMPTS:-1200}"
  local ownerless_stale_seconds="${HARNESS_INSTALL_OWNERLESS_LOCK_STALE_SECONDS:-30}"
  local owner_tmp

  if [[ ! "$max_attempts" =~ ^[0-9]+$ ]] || (( max_attempts < 1 )); then
    printf 'HARNESS_INSTALL_LOCK_ATTEMPTS must be a positive integer\n' >&2
    return 2
  fi
  if [[ ! "$ownerless_stale_seconds" =~ ^[0-9]+$ ]]; then
    printf 'HARNESS_INSTALL_OWNERLESS_LOCK_STALE_SECONDS must be a non-negative integer\n' >&2
    return 2
  fi
  command mkdir -p "$install_root"

  while ! command mkdir "$lock_dir" 2>/dev/null; do
    owner="$(command cat "$lock_dir/owner" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && lock_owner_is_live "$owner"; then
      attempts=$((attempts + 1))
      if (( attempts >= max_attempts )); then
        owner_pid="${owner%%-*}"
        printf 'timed out waiting for install lock held by process %s at %s\n' \
          "$owner_pid" "$lock_dir" >&2
        return 1
      fi
      sleep 0.1
      continue
    fi

    age="$(lock_age_seconds)"
    if [[ -n "$owner" ]] || (( age >= ownerless_stale_seconds )); then
      stale_lock="${lock_dir}.stale-${lock_token}-${attempts}"
      if command mv "$lock_dir" "$stale_lock" 2>/dev/null; then
        command rm -rf "$stale_lock"
      fi
      continue
    fi

    attempts=$((attempts + 1))
    if (( attempts >= max_attempts )); then
      printf 'timed out waiting for owner record at %s\n' "$lock_dir" >&2
      return 1
    fi
    sleep 0.1
  done

  owner_tmp="$lock_dir/.owner-${lock_token}"
  printf '%s\n' "$lock_owner_record" >"$owner_tmp"
  command mv "$owner_tmp" "$lock_dir/owner"
  lock_held=1
}

binary_is_selected() {
  local expected="$1" name
  for name in "${selected_binaries[@]}"; do
    [[ "$name" == "$expected" ]] && return 0
  done
  return 1
}

binary_is_known() {
  local expected="$1" name
  for name in "${all_binaries[@]}"; do
    [[ "$name" == "$expected" ]] && return 0
  done
  return 1
}

harness_cli_is_selected() {
  binary_is_selected harness
}

copy_known_bundle_contents() {
  local source_dir="$1"
  local destination_dir="$2"
  local name source
  [[ -d "$source_dir" ]] || return 0
  for name in "${all_binaries[@]}"; do
    source="$source_dir/$name"
    [[ -f "$source" ]] || continue
    command cp -p "$source" "$destination_dir/$name"
  done
}

backup_entrypoint() {
  local path="$1"
  local backup="${path}.rollback-${lock_token}"
  command rm -f "$backup"
  command cp -pP "$path" "$backup"
  entrypoint_backup_sources+=("$path")
  entrypoint_backup_paths+=("$backup")
}

remove_inactive_managed_entrypoints() {
  local name path
  # bash 3.2 (macOS /bin/bash) treats expanding an empty array under
  # `set -u` as an unbound-variable error; this list is empty on Linux.
  (( ${#HARNESS_RELEASE_INACTIVE_BINARIES[@]} == 0 )) && return 0
  for name in "${HARNESS_RELEASE_INACTIVE_BINARIES[@]}"; do
    path="$(stable_path "$name")"
    if is_managed_link "$name" "$path"; then
      backup_entrypoint "$path"
      command rm -f "$path"
    fi
  done
}

managed_link_target() {
  printf '%s/current/bin/%s\n' "$install_root" "$1"
}

is_managed_link() {
  local name="$1"
  local path="$2"
  [[ -L "$path" ]] || return 1
  [[ "$(command readlink "$path")" == "$(managed_link_target "$name")" ]]
}

normalize_existing_install() {
  local name path direct_count=0 base_id base_dir
  local -a direct_names=()
  local -a direct_paths=()

  if [[ -L "$current_link" && ! -d "$current_link/bin" ]]; then
    printf 'managed current link is broken at %s\n' "$current_link" >&2
    return 1
  fi
  if [[ -e "$current_link" && ! -L "$current_link" ]]; then
    printf 'refusing to replace non-symlink install pointer at %s\n' "$current_link" >&2
    return 1
  fi

  for name in "${selected_binaries[@]}"; do
    path="$(stable_path "$name")"
    if is_managed_link "$name" "$path"; then
      continue
    fi
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      continue
    fi
    if ! normalization_binary_is_owned "$name" "$path"; then
      printf 'refusing to replace non-Harness binary at %s\n' "$path" >&2
      return 1
    fi
    direct_names+=("$name")
    direct_paths+=("$path")
    direct_count=$((direct_count + 1))
  done

  if (( direct_count == 0 )); then
    return 0
  fi

  base_id="legacy-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  base_dir="$install_root/$base_id"
  normalization_stage="$install_root/.${base_id}.staging"
  command rm -rf "$normalization_stage"
  command mkdir -p "$normalization_stage/bin"
  if [[ -L "$current_link" ]]; then
    copy_known_bundle_contents "$current_link/bin" "$normalization_stage/bin"
  fi
  for ((index = 0; index < direct_count; index++)); do
    backup_entrypoint "${direct_paths[index]}"
    command cp -p "${direct_paths[index]}" \
      "$normalization_stage/bin/${direct_names[index]}"
  done
  command mv "$normalization_stage" "$base_dir"
  normalization_stage=""
  normalization_dir_created="$base_dir"
  current_may_have_changed=1
  atomic_replace_symlink "$base_id" "$current_link"

  for ((index = 0; index < direct_count; index++)); do
    atomic_replace_symlink \
      "$(managed_link_target "${direct_names[index]}")" \
      "${direct_paths[index]}"
  done
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    command shasum -a 256 "$1" | command awk '{print $1}'
  else
    command cksum "$1" | command awk '{print $1 "-" $2}'
  fi
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | command shasum -a 256 | command awk '{print substr($1, 1, 16)}'
  else
    printf '%s' "$1" | command cksum | command awk '{print $1}'
  fi
}

validate_release_set_retention() {
  if [[ ! "$release_set_retention" =~ ^[0-9]+$ ]] \
    || (( release_set_retention < 2 )); then
    printf 'HARNESS_INSTALL_RETAIN_RELEASE_SETS must be an integer of at least 2\n' >&2
    return 2
  fi
}

release_set_modified_time() {
  local path="$1" modified
  if modified="$(command stat -f '%m' "$path" 2>/dev/null)" \
    && [[ "$modified" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$modified"
  else
    command stat -c '%Y' "$path"
  fi
}

release_set_is_protected() {
  local expected="$1" protected
  (( ${#protected_release_sets[@]} > 0 )) || return 1
  for protected in "${protected_release_sets[@]}"; do
    [[ "$protected" == "$expected" ]] && return 0
  done
  return 1
}

protect_release_target() {
  local target="$1" name
  [[ -n "$target" ]] || return 0
  target="${target%/}"
  name="${target##*/}"
  [[ -d "$install_root/$name/bin" ]] || return 0
  release_set_is_protected "$name" || protected_release_sets+=("$name")
}

release_executable_physical_path() {
  local path="$1" directory
  directory="$(dirname -- "$path")"
  [[ -d "$directory" ]] || return 1
  printf '%s/%s\n' \
    "$(CDPATH='' command cd -- "$directory" && command pwd -P)" \
    "$(basename -- "$path")"
}

collect_live_release_process_state() {
  local path name executable physical_executable proc_executable target
  local lsof_bin="" lsof_output=""
  local -a executable_candidates=()

  live_executable_paths=""
  live_process_commands=""
  live_process_scan_available=0
  for path in "$install_root"/*; do
    [[ -d "$path/bin" && ! -L "$path" ]] || continue
    name="${path##*/}"
    release_set_is_protected "$name" && continue
    for name in "${all_binaries[@]}"; do
      executable="$path/bin/$name"
      [[ -f "$executable" || -L "$executable" ]] || continue
      physical_executable="$(release_executable_physical_path "$executable")" \
        || continue
      executable_candidates+=("$physical_executable")
    done
  done

  if [[ -d /proc ]]; then
    live_process_scan_available=1
    for proc_executable in /proc/[0-9]*/exe; do
      [[ -L "$proc_executable" ]] || continue
      target="$(command readlink "$proc_executable" 2>/dev/null || true)"
      target="${target% (deleted)}"
      [[ -n "$target" ]] && live_executable_paths+="$target"$'\n'
    done
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof_bin="$(command -v lsof)"
  elif [[ -x /usr/sbin/lsof ]]; then
    lsof_bin=/usr/sbin/lsof
  fi
  if [[ -n "$lsof_bin" && ${#executable_candidates[@]} -gt 0 ]]; then
    live_process_scan_available=1
    lsof_output="$(
      "$lsof_bin" -n -P -F n -- "${executable_candidates[@]}" 2>/dev/null \
        || true
    )"
    while IFS= read -r target; do
      [[ "$target" == n/* ]] || continue
      live_executable_paths+="${target#n}"$'\n'
    done <<<"$lsof_output"
  fi

  if live_process_commands="$(command ps -ww -axo command= 2>/dev/null)"; then
    live_process_scan_available=1
  else
    live_process_commands=""
  fi
}

release_executable_is_live() {
  local executable="$1" physical_executable live_path command_line
  local process_executable process_script _
  physical_executable="$(release_executable_physical_path "$executable")" \
    || return 1

  while IFS= read -r live_path; do
    if [[ "$live_path" == "$executable" \
      || "$live_path" == "$physical_executable" ]]; then
      return 0
    fi
  done <<<"$live_executable_paths"

  while IFS= read -r command_line; do
    read -r process_executable process_script _ <<<"$command_line"
    if [[ "$process_executable" == "$executable" \
      || "$process_executable" == "$physical_executable" \
      || "$process_script" == "$executable" \
      || "$process_script" == "$physical_executable" ]]; then
      return 0
    fi
  done <<<"$live_process_commands"
  return 1
}

protect_live_release_targets() {
  local path name executable
  collect_live_release_process_state
  (( live_process_scan_available == 1 )) || return 1

  for path in "$install_root"/*; do
    [[ -d "$path/bin" && ! -L "$path" ]] || continue
    for name in "${all_binaries[@]}"; do
      executable="$path/bin/$name"
      [[ -f "$executable" || -L "$executable" ]] || continue
      if release_executable_is_live "$executable"; then
        protect_release_target "$path"
        break
      fi
    done
  done
}

prune_release_sets() {
  local active_target path name modified_time
  local protected_count keep_unprotected seen_unprotected=0
  local -a release_set_entries=()

  active_target="$(command readlink "$current_link" 2>/dev/null || true)"
  protected_release_sets=()
  protect_release_target "$active_target"
  protect_release_target "$previous_target"
  protect_release_target "$original_current_target"
  protected_count=${#protected_release_sets[@]}
  keep_unprotected=$((release_set_retention - protected_count))
  (( keep_unprotected > 0 )) || keep_unprotected=0

  for path in "$install_root"/*; do
    [[ -d "$path/bin" && ! -L "$path" ]] || continue
    name="${path##*/}"
    release_set_is_protected "$name" && continue
    modified_time="$(release_set_modified_time "$path")"
    release_set_entries+=("$modified_time|$name")
  done
  (( ${#release_set_entries[@]} > keep_unprotected )) || return 0

  if ! protect_live_release_targets; then
    printf 'warning: unable to inspect live release executables; skipping retention pruning\n' >&2
    return 0
  fi
  protected_count=${#protected_release_sets[@]}
  keep_unprotected=$((release_set_retention - protected_count))
  (( keep_unprotected > 0 )) || keep_unprotected=0
  release_set_entries=()
  for path in "$install_root"/*; do
    [[ -d "$path/bin" && ! -L "$path" ]] || continue
    name="${path##*/}"
    release_set_is_protected "$name" && continue
    modified_time="$(release_set_modified_time "$path")"
    release_set_entries+=("$modified_time|$name")
  done
  (( ${#release_set_entries[@]} > keep_unprotected )) || return 0

  printf '%s\n' "${release_set_entries[@]}" \
    | LC_ALL=C command sort -t '|' -k1,1nr -k2,2r \
    | while IFS='|' read -r _ name; do
      [[ -n "$name" ]] || continue
      if (( seen_unprotected < keep_unprotected )); then
        seen_unprotected=$((seen_unprotected + 1))
        continue
      fi
      command rm -rf "$install_root/$name"
    done
}

validate_selected_sources() {
  local name source
  for name in "${selected_binaries[@]}"; do
    source="$(build_path "$name")"
    if [[ ! -x "$source" ]]; then
      printf 'expected release binary missing at %s\n' "$source" >&2
      return 1
    fi
    if ! binary_is_owned "$name" "$source"; then
      printf 'release artifact failed its identity probe at %s\n' "$source" >&2
      return 1
    fi
  done
}

expected_core_version() {
  local name path current_harness_path current_aff_path
  # $target_dir/release persists across invocations, so checking a fixed
  # path like build_path(harness) would pick up a stale artifact left by an
  # earlier "all"/"harness" build even when harness isn't part of this
  # selection. Only consider binaries actually selected this run.
  for name in "${selected_binaries[@]}"; do
    case "$name" in
      harness-codex-acp | harness-openrouter-agent) continue ;;
    esac
    path="$(build_path "$name")"
    if [[ -x "$path" ]]; then
      binary_version "$path"
      return
    fi
  done
  # No selected binary carries a version (e.g. a codex/openrouter-only
  # install); fall back to whichever is already active so the candidate
  # still gets a meaningful version-derived identity.
  current_harness_path="$current_link/bin/harness"
  if [[ -x "$current_harness_path" ]]; then
    binary_version "$current_harness_path"
    return
  fi
  current_aff_path="$current_link/bin/aff"
  if [[ -x "$current_aff_path" ]]; then
    binary_version "$current_aff_path"
  fi
}

validate_exact_inventory() {
  local bin_dir="$1"
  local path name
  for path in "$bin_dir"/*; do
    name="$(basename -- "$path")"
    if ! binary_is_known "$name"; then
      printf 'candidate contains unknown binary %s\n' "$path" >&2
      return 1
    fi
    if [[ ! -f "$path" || ! -x "$path" ]]; then
      printf 'candidate entry is not an executable file: %s\n' "$path" >&2
      return 1
    fi
  done

  for name in "${selected_binaries[@]}"; do
    if [[ ! -f "$bin_dir/$name" ]]; then
      printf 'candidate is missing selected binary %s\n' "$name" >&2
      return 1
    fi
  done
  if (( requested_all == 1 )); then
    for name in "${all_binaries[@]}"; do
      if [[ ! -f "$bin_dir/$name" ]]; then
        printf 'full candidate is missing binary %s\n' "$name" >&2
        return 1
      fi
    done
  fi
}

validate_candidate_set() {
  local bin_dir="$1"
  local expected_version="$2"
  local name path actual_version
  validate_exact_inventory "$bin_dir"
  for name in "${all_binaries[@]}"; do
    path="$bin_dir/$name"
    [[ -f "$path" ]] || continue
    if ! binary_is_owned "$name" "$path"; then
      printf 'candidate %s failed its identity probe at %s\n' "$name" "$path" >&2
      return 1
    fi
    if binary_is_selected "$name"; then
      case "$name" in
        harness-codex-acp|harness-openrouter-agent)
          ;;
        *)
          actual_version="$(binary_version "$path")"
          if [[ "$actual_version" != "$expected_version" ]]; then
            printf 'candidate %s version %s != expected %s\n' \
              "$name" "${actual_version:-unknown}" "$expected_version" >&2
            return 1
          fi
          ;;
      esac
    fi
    if ! codesign_is_skipped "$name"; then
      command codesign --verify --strict --verbose=2 "$path" >/dev/null
    fi
  done
}

prepare_candidate() {
  local expected_version="$1"
  local digest_input="${selected_binaries[*]}|$previous_target|$harness_signing_identity|$aff_signing_identity|$harness_skip_codesign|$aff_skip_codesign"
  local name source checksum build_id candidate_id candidate_dir identity

  candidate_stage="$install_root/.candidate-${lock_token}.staging"
  command rm -rf "$candidate_stage"
  command mkdir -p "$candidate_stage/bin"
  if (( requested_all == 0 )); then
    copy_known_bundle_contents "$current_link/bin" "$candidate_stage/bin"
  fi

  for name in "${selected_binaries[@]}"; do
    source="$(build_path "$name")"
    command rm -f "$candidate_stage/bin/$name"
    command cp "$source" "$candidate_stage/bin/$name"
    command chmod 755 "$candidate_stage/bin/$name"
    if ! codesign_is_skipped "$name"; then
      identity="$(signing_identity_for "$name")"
      command codesign --force --options=runtime -s "$identity" \
        "$candidate_stage/bin/$name"
    fi
    command chmod 555 "$candidate_stage/bin/$name"
  done

  validate_candidate_set "$candidate_stage/bin" "$expected_version"
  for name in "${all_binaries[@]}"; do
    source="$candidate_stage/bin/$name"
    if [[ -f "$source" ]]; then
      checksum="$(hash_file "$source")"
      digest_input+="|$name:$checksum"
    else
      digest_input+="|$name:absent"
    fi
  done
  build_id="$(hash_text "$digest_input")"
  candidate_id="${expected_version//[^[:alnum:]._-]/-}-$build_id"
  candidate_dir="$install_root/$candidate_id"
  if [[ -e "$candidate_dir" ]]; then
    candidate_id="$candidate_id-$lock_token"
    candidate_dir="$install_root/$candidate_id"
  fi
  command mv "$candidate_stage" "$candidate_dir"
  candidate_stage=""
  candidate_dir_created="$candidate_dir"
  prepared_candidate_id="$candidate_id"
}

shadow_reconciliation_opted_out() {
  local candidate="$1"
  local cargo_home="${CARGO_HOME:-${HOME}/.cargo}"
  [[ "${HARNESS_INSTALL_REMOVE_CARGO_SHADOW:-1}" == "0" ]] \
    && [[ "$candidate" == "$cargo_home/bin/harness" ]]
}

preflight_shadowed_harness_binaries() {
  local path_entry candidate candidate_dir existing
  shadow_candidates=()
  IFS=: read -r -a path_entries <<<"${PATH:-}"
  (( ${#path_entries[@]} == 0 )) && return 0
  for path_entry in "${path_entries[@]}"; do
    [[ -n "$path_entry" ]] || continue
    candidate="$path_entry/harness"
    [[ -x "$candidate" ]] || continue
    if [[ "$candidate" == "$(stable_path harness)" ]] \
      || [[ "$candidate" -ef "$(stable_path harness)" ]]; then
      continue
    fi
    if (( ${#shadow_candidates[@]} > 0 )); then
      for existing in "${shadow_candidates[@]}"; do
        [[ "$existing" == "$candidate" ]] && continue 2
      done
    fi
    if shadow_reconciliation_opted_out "$candidate"; then
      printf 'unable to reconcile %s because HARNESS_INSTALL_REMOVE_CARGO_SHADOW=0\n' \
        "$candidate" >&2
      return 1
    fi
    if ! binary_is_owned harness "$candidate"; then
      printf 'refusing to overwrite non-Harness CLI shadow binary at %s\n' "$candidate" >&2
      return 1
    fi
    candidate_dir="$(dirname -- "$candidate")"
    if [[ ! -w "$candidate_dir" ]]; then
      printf 'unable to reconcile shadowed harness binary at %s because %s is not writable\n' \
        "$candidate" "$candidate_dir" >&2
      return 1
    fi
    shadow_candidates+=("$candidate")
  done
}

reconcile_shadowed_harness_binaries() {
  local candidate backup reconciled_count=0
  (( ${#shadow_candidates[@]} > 0 )) || return 0
  for candidate in "${shadow_candidates[@]}"; do
    backup="${candidate}.rollback-${lock_token}"
    command rm -f "$backup"
    command cp -pP "$candidate" "$backup"
    shadow_backup_sources+=("$candidate")
    shadow_backup_paths+=("$backup")
    atomic_replace_symlink "$(stable_path harness)" "$candidate"
    reconciled_count=$((reconciled_count + 1))
    printf 'reconciled shadowed harness binary at %s -> %s\n' \
      "$candidate" "$(stable_path harness)" >&2
    if [[ "${HARNESS_INSTALL_TEST_FAIL_AFTER_SHADOWS:-}" == "$reconciled_count" ]]; then
      printf 'injected shadow reconciliation failure\n' >&2
      return 98
    fi
  done
}

config_contains_legacy_command() {
  local path="$1" normalized
  normalized="$(LC_ALL=C command tr -cs '[:alnum:]_./-' ' ' <"$path")"
  printf '%s\n' "$normalized" | command grep -Eq \
    'command[[:space:]]+harness[[:space:]]+(args[[:space:]]+)?(hook|mcp[[:space:]]+serve|pre-compact|session-start|session-stop|agents[[:space:]]+(session-start|session-stop|prompt-submit))'
}

detect_legacy_runtime_configs() {
  local project_root="${HARNESS_INSTALL_LEGACY_CONFIG_ROOT:-$PWD}"
  local path seen="|"
  local -a config_paths=(
    "$project_root/.claude/settings.json"
    "$project_root/.gemini/settings.json"
    "$project_root/.vibe/hooks.json"
    "$project_root/.opencode/hooks.json"
    "$project_root/.github/hooks/harness.json"
    "$project_root/.mcp.json"
    "$HOME/.claude/settings.json"
    "$HOME/.gemini/settings.json"
    "$HOME/.vibe/settings.json"
    "$HOME/.opencode/config.json"
  )

  harness_cli_is_selected || return 0
  for path in "${config_paths[@]}"; do
    [[ "$seen" != *"|$path|"* ]] || continue
    seen+="$path|"
    [[ -f "$path" ]] || continue
    if config_contains_legacy_command "$path"; then
      printf 'legacy Harness runtime command found in %s\n' "$path" >&2
      printf '%s\n' \
        "run \`mise run setup:bootstrap\` and \`mise run mcp:register-claude add\`, then rerun \`mise run install\`" >&2
      return 1
    fi
  done
}

cleanup_cli_launch_agent() {
  local harness_path
  harness_cli_is_selected || return 0
  [[ "${HARNESS_INSTALL_CLEANUP_CLI_DAEMON:-1}" != "0" ]] || return 0
  harness_path="$(stable_path harness)"
  if ! command env -u HARNESS_APP_GROUP_ID -u HARNESS_DAEMON_DATA_HOME \
    -u HARNESS_SANDBOXED "$harness_path" daemon stop --json >/dev/null 2>&1; then
    printf 'warning: unable to stop existing CLI daemon; continuing binary install\n' >&2
  fi
  if ! command env -u HARNESS_APP_GROUP_ID -u HARNESS_DAEMON_DATA_HOME \
    -u HARNESS_SANDBOXED "$harness_path" daemon remove-launch-agent --json >/dev/null 2>&1; then
    printf 'warning: unable to remove existing CLI launch agent; continuing binary install\n' >&2
  fi
}

release_pipeline_lock_acquire "$target_dir"
validate_selected_sources
validate_release_set_retention
detect_legacy_runtime_configs
acquire_lock
if [[ -n "${HARNESS_INSTALL_TEST_HOLD_LOCK_SECONDS:-}" ]]; then
  sleep "$HARNESS_INSTALL_TEST_HOLD_LOCK_SECONDS"
fi
if [[ -L "$current_link" ]]; then
  original_current_target="$(command readlink "$current_link")"
fi
normalize_existing_install
previous_target="$(command readlink "$current_link" 2>/dev/null || true)"
expected_version="$(expected_core_version)"
if [[ -z "$expected_version" ]]; then
  printf 'failed to read expected release version\n' >&2
  exit 1
fi

shadow_candidates=()
if harness_cli_is_selected; then
  preflight_shadowed_harness_binaries
fi

prepared_candidate_id=""
prepare_candidate "$expected_version"
candidate_id="$prepared_candidate_id"
candidate_dir="$install_root/$candidate_id"

current_may_have_changed=1
# Activate the complete candidate before publishing any new stable entrypoint.
# Existing entrypoints switch with `current`; first-install links are never dangling.
atomic_replace_symlink "$candidate_id" "$current_link"
remove_inactive_managed_entrypoints
if [[ "${HARNESS_INSTALL_TEST_FAIL_AFTER_ACTIVATION:-0}" == "1" ]]; then
  printf 'injected post-activation failure\n' >&2
  exit 97
fi
if [[ -n "${HARNESS_INSTALL_TEST_HOLD_AFTER_ACTIVATION_SECONDS:-}" ]]; then
  sleep "$HARNESS_INSTALL_TEST_HOLD_AFTER_ACTIVATION_SECONDS"
fi

published_link_count=0
for name in "${selected_binaries[@]}"; do
  path="$(stable_path "$name")"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    created_links+=("$path")
  fi
  atomic_replace_symlink "$(managed_link_target "$name")" "$path"
  published_link_count=$((published_link_count + 1))
  if [[ "${HARNESS_INSTALL_TEST_FAIL_AFTER_ENTRYPOINTS:-}" == "$published_link_count" ]]; then
    printf 'injected entrypoint publication failure\n' >&2
    exit 96
  fi
done

validate_candidate_set "$current_link/bin" "$expected_version"
if harness_cli_is_selected; then
  reconcile_shadowed_harness_binaries
fi
prune_release_sets

completed=1
cleanup_cli_launch_agent
printf 'installed %s release set %s at %s (entrypoints: %s, aff: %s)\n' \
  "${selectors[*]}" "$candidate_id" "$candidate_dir" "$harness_binary_dir" "$aff_binary_dir"
