#!/usr/bin/env bash
# Render, install, query, and uninstall the LaunchAgent that runs
# scripts/prune-xcode-derived-profiles.sh on a periodic schedule.
#
# Subcommands:
#   install            - render template into ~/Library/LaunchAgents and bootstrap
#   uninstall          - bootout + delete the rendered plist
#   reinstall          - uninstall + install (use after changing interval)
#   status             - launchctl print + interval + last run timestamp
#   run-now            - one-shot prune; passes through env knobs
#   show-plist         - print the rendered plist that would be installed
#
# Env:
#   HARNESS_MONITOR_PROFILE_PRUNE_INTERVAL_SECONDS  schedule in seconds
#                                                   (default: 7200 = 2h)
#   HARNESS_MONITOR_PROFILE_TTL_SECONDS             prune staleness threshold
#                                                   (default: matches interval)
#   HARNESS_MONITOR_PROFILE_DRY_RUN                 1 to skip /bin/rm during run-now
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$SCRIPT_DIR/launchd/io.harnessmonitor.prune-xcode-derived-profiles.plist.template"
LABEL="io.harnessmonitor.prune-xcode-derived-profiles"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
INTERVAL_SECONDS="${HARNESS_MONITOR_PROFILE_PRUNE_INTERVAL_SECONDS:-7200}"

usage() {
  /usr/bin/sed -n '2,20p' "$0"
  exit "${1:-0}"
}

require_template() {
  if [[ ! -f "$TEMPLATE_PATH" ]]; then
    printf 'manage-prune-launch-agent: template missing at %s\n' "$TEMPLATE_PATH" >&2
    exit 1
  fi
}

render_plist() {
  local out_path="$1"
  /bin/mkdir -p "$(/usr/bin/dirname "$out_path")"
  /usr/bin/sed \
    -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    -e "s|__INTERVAL_SECONDS__|${INTERVAL_SECONDS}|g" \
    "$TEMPLATE_PATH" > "$out_path"
}

launchd_domain() {
  local uid
  uid="$(id -u)"
  printf 'gui/%s' "$uid"
}

bootstrap_agent() {
  local domain
  domain="$(launchd_domain)"
  if launchctl print "${domain}/${LABEL}" >/dev/null 2>&1; then
    launchctl bootout "${domain}/${LABEL}" 2>/dev/null || true
  fi
  launchctl bootstrap "$domain" "$PLIST_PATH"
  launchctl enable "${domain}/${LABEL}"
}

bootout_agent() {
  local domain
  domain="$(launchd_domain)"
  if launchctl print "${domain}/${LABEL}" >/dev/null 2>&1; then
    launchctl bootout "${domain}/${LABEL}" 2>/dev/null || true
  fi
}

cmd_install() {
  require_template
  /bin/mkdir -p "$REPO_ROOT/tmp"
  render_plist "$PLIST_PATH"
  bootstrap_agent
  printf 'installed %s (interval=%ss, plist=%s)\n' "$LABEL" "$INTERVAL_SECONDS" "$PLIST_PATH"
}

cmd_uninstall() {
  bootout_agent
  if [[ -f "$PLIST_PATH" ]]; then
    /bin/rm -f "$PLIST_PATH"
    printf 'removed %s\n' "$PLIST_PATH"
  fi
  printf 'uninstalled %s\n' "$LABEL"
}

cmd_reinstall() {
  cmd_uninstall
  cmd_install
}

cmd_status() {
  local domain
  domain="$(launchd_domain)"
  if [[ -f "$PLIST_PATH" ]]; then
    printf 'plist=%s\n' "$PLIST_PATH"
    /usr/bin/grep -E 'StartInterval|HARNESS_MONITOR_PROFILE_TTL_SECONDS' -A 1 "$PLIST_PATH" \
      | /usr/bin/sed 's/^/  /'
  else
    printf 'plist=<missing> (run: mise run monitor:gc:profiles:install)\n'
  fi
  printf '\nlaunchctl print %s/%s:\n' "$domain" "$LABEL"
  if ! launchctl print "${domain}/${LABEL}" 2>/dev/null \
        | /usr/bin/grep -E 'state|last exit code|last exit reason|run interval|program' \
        | /usr/bin/sed 's/^/  /'; then
    printf '  (not loaded)\n'
  fi
  printf '\nrecent stdout (%s):\n' "$REPO_ROOT/tmp/prune-xcode-derived-profiles.out.log"
  if [[ -f "$REPO_ROOT/tmp/prune-xcode-derived-profiles.out.log" ]]; then
    /usr/bin/tail -n 5 "$REPO_ROOT/tmp/prune-xcode-derived-profiles.out.log" | /usr/bin/sed 's/^/  /'
  else
    printf '  (no log yet)\n'
  fi
}

cmd_run_now() {
  exec env \
    HARNESS_MONITOR_PROFILE_TTL_SECONDS="${HARNESS_MONITOR_PROFILE_TTL_SECONDS:-$INTERVAL_SECONDS}" \
    HARNESS_MONITOR_PROFILE_DRY_RUN="${HARNESS_MONITOR_PROFILE_DRY_RUN:-0}" \
    /bin/bash "$REPO_ROOT/scripts/prune-xcode-derived-profiles.sh"
}

cmd_show_plist() {
  require_template
  render_plist /dev/stdout
}

case "${1:-}" in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  reinstall) cmd_reinstall ;;
  status) cmd_status ;;
  run-now) cmd_run_now ;;
  show-plist) cmd_show_plist ;;
  -h|--help|help) usage 0 ;;
  '') usage 1 ;;
  *)
    printf 'unknown subcommand: %s\n\n' "$1" >&2
    usage 1
    ;;
esac
