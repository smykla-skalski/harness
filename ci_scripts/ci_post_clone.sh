#!/bin/bash
set -euo pipefail

# Xcode Cloud clones tracked sources only. Generate the Tuist workspace before
# the archive action resolves the HarnessMonitor scheme.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
MISE_BIN="${MISE_BIN:-mise}"
MISE_INSTALLER_PATH=""

cleanup() {
  if [ -n "$MISE_INSTALLER_PATH" ]; then
    /bin/rm -f "$MISE_INSTALLER_PATH"
  fi
}
trap cleanup EXIT

find_or_install_mise() {
  local install_path

  if command -v "$MISE_BIN" >/dev/null 2>&1; then
    MISE_BIN="$(command -v "$MISE_BIN")"
    return 0
  fi

  install_path="${MISE_INSTALL_PATH:-$HOME/.local/bin/mise}"
  if [ -x "$install_path" ]; then
    MISE_BIN="$install_path"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf 'ci_post_clone: mise is required, and curl is unavailable to install it.\n' >&2
    return 1
  fi

  /bin/mkdir -p "$(dirname -- "$install_path")"
  MISE_INSTALLER_PATH="$(mktemp "${TMPDIR:-/tmp}/mise-install.XXXXXX")"
  curl -fsSL https://mise.run -o "$MISE_INSTALLER_PATH"
  MISE_INSTALL_PATH="$install_path" /bin/sh "$MISE_INSTALLER_PATH"

  if [ ! -x "$install_path" ]; then
    printf 'ci_post_clone: mise installer did not create %s.\n' "$install_path" >&2
    return 1
  fi

  MISE_BIN="$install_path"
}

find_or_install_mise

export MISE_YES=1
export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:+$MISE_TRUSTED_CONFIG_PATHS:}$ROOT/.mise.toml"

cd "$ROOT"
"$MISE_BIN" install tuist
"$MISE_BIN" run monitor:generate
