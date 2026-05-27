#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$APP_ROOT/../.." && pwd)"
PERF_CLI_PACKAGE_DIR="$APP_ROOT/Tools/HarnessMonitorPerf"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
source "$SCRIPT_DIR/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-package-freshness.sh
source "$SCRIPT_DIR/lib/swift-package-freshness.sh"
sanitize_xcode_only_swift_environment
WORKTREE_ROOT="${HARNESS_MONITOR_AUDIT_WORKTREE_ROOT:-/private/tmp}"

PERF_CLI_BINARY="$(
  ensure_swift_package_release_binary_fresh \
    "$PERF_CLI_PACKAGE_DIR" \
    "harness-monitor-perf"
)"

good_ref=""
bad_ref=""
audit_label=""
worktree_root="$WORKTREE_ROOT"
dry_run=0
keep_worktree=0
passthrough=()

usage() {
  cat <<'EOF'
Usage:
  run-instruments-audit-bisect.sh --good-ref <commit-ish> --bad-ref <commit-ish> --label <name> [audit options...]

Options:
  --good-ref <commit-ish>  Required known-good git ref.
  --bad-ref <commit-ish>   Required known-bad git ref.
  --label <name>           Required audit label prefix.
  --worktree-root <dir>    Optional parent directory for the temporary worktree.
                           Default: /private/tmp or HARNESS_MONITOR_AUDIT_WORKTREE_ROOT.
  --dry-run                Print the bisect plan and generated runner script.
  --keep-worktree          Keep the temporary bisect worktree after completion.
  -h, --help               Show this help.

All remaining arguments are forwarded to `harness-monitor-perf audit`.
The generated bisect runner treats infrastructure failures as git-bisect skip
and budget failures as the bad predicate.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --good-ref)
      good_ref="$2"; shift 2 ;;
    --bad-ref)
      bad_ref="$2"; shift 2 ;;
    --label)
      audit_label="$2"; shift 2 ;;
    --worktree-root)
      worktree_root="$2"; shift 2 ;;
    --dry-run)
      dry_run=1; shift ;;
    --keep-worktree)
      keep_worktree=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      passthrough+=("$1"); shift ;;
  esac
done

if [[ -z "$good_ref" ]]; then
  printf 'Missing required --good-ref\n' >&2; usage >&2; exit 1
fi
if [[ -z "$bad_ref" ]]; then
  printf 'Missing required --bad-ref\n' >&2; usage >&2; exit 1
fi
if [[ -z "$audit_label" ]]; then
  printf 'Missing required --label\n' >&2; usage >&2; exit 1
fi

cmd=(
  "$PERF_CLI_BINARY" audit-bisect
  --good-ref "$good_ref"
  --bad-ref "$bad_ref"
  --label "$audit_label"
  --checkout-root "$CHECKOUT_ROOT"
  --worktree-root "$worktree_root"
)
if ((dry_run)); then
  cmd+=("--dry-run")
fi
if ((keep_worktree)); then
  cmd+=("--keep-worktree")
fi
if ((${#passthrough[@]} > 0)); then
  for arg in "${passthrough[@]}"; do
    cmd+=("--passthrough=$arg")
  done
fi

"${cmd[@]}"
