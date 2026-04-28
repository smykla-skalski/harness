#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"
PLUGIN_NAME="council"
MARKETPLACE_NAME="harness"
PLUGIN_SOURCE_DIR="${ROOT}/plugins/${PLUGIN_NAME}"
PLUGIN_MANIFEST="${PLUGIN_SOURCE_DIR}/plugin.json"
CONFIG_PATH="${CODEX_HOME_DIR}/config.toml"
CACHE_ROOT="${CODEX_HOME_DIR}/plugins/cache/${MARKETPLACE_NAME}"
PLUGIN_CACHE_DIR="${CACHE_ROOT}/${PLUGIN_NAME}"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

plugin_version() {
  local version
  version="$(awk -F'"' '$2 == "version" { print $4; exit }' "${PLUGIN_MANIFEST}")"
  [[ -n "${version}" ]] || fail "unable to read council plugin version from ${PLUGIN_MANIFEST}"
  printf '%s\n' "${version}"
}

strip_managed_sections() {
  local source_path="$1"
  local output_path="$2"

  if [[ ! -f "${source_path}" ]]; then
    : > "${output_path}"
    return 0
  fi

  awk \
    -v plugin_current='[plugins."council@council"]' \
    -v plugin_legacy='[plugins."council@council-home"]' \
    -v plugin_target='[plugins."council@harness"]' \
    -v marketplace_current='[marketplaces.council]' \
    -v marketplace_legacy='[marketplaces.council-home]' \
    -v marketplace_target='[marketplaces.harness]' '
      function managed_header(header) {
        return (header == plugin_current || header == plugin_legacy || header == plugin_target || header == marketplace_current || header == marketplace_legacy || header == marketplace_target)
      }

      /^\[/ {
        skip = managed_header($0)
      }
      !skip { print }
    ' "${source_path}" > "${output_path}"
}

install_plugin_cache() {
  local version="$1"
  local stage_dir backup_dir

  mkdir -p "${CACHE_ROOT}"
  stage_dir="$(mktemp -d "${CACHE_ROOT}/.${PLUGIN_NAME}.stage.XXXXXX")"
  backup_dir="${PLUGIN_CACHE_DIR}.bak.$$"
  trap 'rm -rf "${stage_dir}" "${backup_dir}"' EXIT

  cp -R "${PLUGIN_SOURCE_DIR}" "${stage_dir}/${version}"

  if [[ -e "${PLUGIN_CACHE_DIR}" ]]; then
    mv "${PLUGIN_CACHE_DIR}" "${backup_dir}"
  fi

  mv "${stage_dir}" "${PLUGIN_CACHE_DIR}"
  rm -rf "${backup_dir}"
  trap - EXIT
}

write_config() {
  local repo_source="$1"
  local now="$2"
  local tmp_config

  mkdir -p "${CODEX_HOME_DIR}"
  tmp_config="$(mktemp "${CODEX_HOME_DIR}/config.toml.XXXXXX")"
  strip_managed_sections "${CONFIG_PATH}" "${tmp_config}"

  {
    cat "${tmp_config}"
    printf '\n[plugins."council@harness"]\n'
    printf 'enabled = true\n'
    printf '\n[marketplaces.harness]\n'
    printf 'last_updated = "%s"\n' "${now}"
    printf 'source_type = "local"\n'
    printf 'source = "%s"\n' "${repo_source}"
  } > "${tmp_config}.next"

  mv "${tmp_config}.next" "${CONFIG_PATH}"
  rm -f "${tmp_config}"
}

main() {
  [[ -d "${PLUGIN_SOURCE_DIR}" ]] || fail "missing rendered council plugin at ${PLUGIN_SOURCE_DIR}; run \`rtk mise run setup:agents:generate\` first"
  [[ -f "${PLUGIN_MANIFEST}" ]] || fail "missing rendered council plugin manifest at ${PLUGIN_MANIFEST}; run \`rtk mise run setup:agents:generate\` first"

  local version now
  version="$(plugin_version)"
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  install_plugin_cache "${version}"
  write_config "${ROOT}" "${now}"

  log "Installed council plugin ${version} into ${PLUGIN_CACHE_DIR}/${version}"
  log "Enabled council as council@harness in ${CONFIG_PATH}"
  log "Set harness marketplace source to ${ROOT}"
}

main "$@"
