#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$APP_ROOT/../.." && pwd)"
PERF_CLI_PACKAGE_DIR="$APP_ROOT/Tools/HarnessMonitorPerf"
PERF_CLI_BINARY="$PERF_CLI_PACKAGE_DIR/.build/release/harness-monitor-perf"
WORKTREE_ROOT="${HARNESS_MONITOR_AUDIT_WORKTREE_ROOT:-/private/tmp}"

if [[ ! -x "$PERF_CLI_BINARY" ]]; then
  printf 'Building harness-monitor-perf Swift CLI...\n' >&2
  swift build -c release --package-path "$PERF_CLI_PACKAGE_DIR" >&2
fi

ref=""
audit_label=""
worktree_root="$WORKTREE_ROOT"
passthrough=()

usage() {
  cat <<'EOF'
Usage:
  run-instruments-audit-from-ref.sh --ref <commit-ish> --label <name> [audit options...]

Options:
  --ref <commit-ish>     Required git ref or commit to audit from a temporary worktree.
  --label <name>         Required audit label.
  --worktree-root <dir>  Optional parent directory for the temporary worktree.
                         Default: /private/tmp or HARNESS_MONITOR_AUDIT_WORKTREE_ROOT.
  -h, --help             Show this help.

All remaining arguments are forwarded to `harness-monitor-perf audit`.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      ref="$2"; shift 2 ;;
    --label)
      audit_label="$2"; shift 2 ;;
    --worktree-root)
      worktree_root="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      passthrough+=("$1"); shift ;;
  esac
done

if [[ -z "$ref" ]]; then
  printf 'Missing required --ref\n' >&2; usage >&2; exit 1
fi
if [[ -z "$audit_label" ]]; then
  printf 'Missing required --label\n' >&2; usage >&2; exit 1
fi

cmd=(
  "$PERF_CLI_BINARY" audit-from-ref
  --ref "$ref"
  --label "$audit_label"
  --checkout-root "$CHECKOUT_ROOT"
  --worktree-root "$worktree_root"
)
if ((${#passthrough[@]} > 0)); then
  cmd+=(--passthrough "${passthrough[@]}")
fi

"${cmd[@]}"
