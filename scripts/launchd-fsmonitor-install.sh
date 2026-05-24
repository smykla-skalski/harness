#!/usr/bin/env bash
# Install / uninstall the weekly fsmonitor cleanup launchd agent.
#
# Usage:
#   scripts/launchd-fsmonitor-install.sh install
#   scripts/launchd-fsmonitor-install.sh remove
#   scripts/launchd-fsmonitor-install.sh status
#
# Install:
#   - renders the plist template to ~/Library/LaunchAgents/com.smykla.harness.fsmonitor-cleanup.plist
#     filling in the absolute script path, repo root, and log path
#   - launchctl bootstraps it into the current GUI session so it survives
#     logout / login until explicitly removed
#
# Remove:
#   - launchctl bootouts the agent and removes the plist file
#
# Status: prints the agent's current state (loaded? last fire?).
set -uo pipefail

LABEL="com.smykla.harness.fsmonitor-cleanup"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PLIST="$REPO_ROOT/scripts/launchd/${LABEL}.plist"
INSTALLED_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
CLEANUP_SCRIPT="$REPO_ROOT/scripts/launchd-fsmonitor-cleanup.sh"
LOG_DIR="$HOME/Library/Logs/HarnessFsmonitorCleanup"

ACTION="${1:-help}"
SERVICE_TARGET="gui/$(/usr/bin/id -u)/${LABEL}"
DOMAIN_TARGET="gui/$(/usr/bin/id -u)"

render_plist() {
  /usr/bin/sed \
    -e "s|__SCRIPT_PATH__|${CLEANUP_SCRIPT}|g" \
    -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    -e "s|__LOG_PATH__|${LOG_DIR}|g" \
    "$TEMPLATE_PLIST"
}

case "$ACTION" in
  install)
    [[ -f "$TEMPLATE_PLIST" ]] || { printf 'missing template plist: %s\n' "$TEMPLATE_PLIST" >&2; exit 2; }
    [[ -x "$CLEANUP_SCRIPT" ]] || /bin/chmod +x "$CLEANUP_SCRIPT"
    /bin/mkdir -p "$LOG_DIR"
    /bin/mkdir -p "$(/usr/bin/dirname "$INSTALLED_PLIST")"
    render_plist > "$INSTALLED_PLIST"
    /usr/bin/plutil -lint "$INSTALLED_PLIST" >/dev/null
    # `bootout` first in case an older copy is loaded under the same label.
    /bin/launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true
    /bin/launchctl bootstrap "$DOMAIN_TARGET" "$INSTALLED_PLIST"
    printf 'installed: %s\nlogs: %s\nverify: launchctl print %s\n' \
      "$INSTALLED_PLIST" "$LOG_DIR" "$SERVICE_TARGET"
    ;;

  remove)
    /bin/launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true
    if [[ -f "$INSTALLED_PLIST" ]]; then
      /bin/rm "$INSTALLED_PLIST"
      printf 'removed: %s\n' "$INSTALLED_PLIST"
    else
      printf 'no plist at %s; nothing to remove\n' "$INSTALLED_PLIST"
    fi
    ;;

  status)
    if [[ -f "$INSTALLED_PLIST" ]]; then
      printf 'plist installed: %s\n' "$INSTALLED_PLIST"
    else
      printf 'plist NOT installed at %s\n' "$INSTALLED_PLIST"
    fi
    printf '\nlaunchctl print %s:\n' "$SERVICE_TARGET"
    { /bin/launchctl print "$SERVICE_TARGET" 2>&1 || true; } | /usr/bin/head -30 || true
    printf '\nrecent log entries (most recent first):\n'
    /bin/ls -1t "$LOG_DIR"/cleanup-*.log 2>/dev/null | /usr/bin/head -3 || true
    exit 0
    ;;

  help|--help|-h)
    /usr/bin/sed -n '2,17p' "$0"
    ;;

  *)
    printf 'unknown action: %s\n' "$ACTION" >&2
    exit 2
    ;;
esac
