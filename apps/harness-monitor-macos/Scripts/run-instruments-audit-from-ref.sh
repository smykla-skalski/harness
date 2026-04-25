#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$APP_ROOT/../.." && pwd)"
WORKTREE_ROOT="${HARNESS_MONITOR_AUDIT_WORKTREE_ROOT:-/private/tmp}"

usage() {
  cat <<'EOF'
Usage:
  run-instruments-audit-from-ref.sh --ref <commit-ish> --label <name> [run-instruments-audit options...]

Options:
  --ref <commit-ish>     Required git ref or commit to audit from a temporary worktree.
  --worktree-root <dir>  Optional parent directory for the temporary worktree.
                         Default: /private/tmp or HARNESS_MONITOR_AUDIT_WORKTREE_ROOT.
  -h, --help             Show this help.

All remaining arguments are passed through to run-instruments-audit.sh.
This wrapper always creates a temporary detached worktree, runs `mise trust`
inside it, executes the audit there, verifies manifest provenance, and cleans
the worktree on exit.
EOF
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

ref=""
audit_label=""
worktree_root="$WORKTREE_ROOT"
audit_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      if [[ $# -lt 2 ]]; then
        printf 'Missing value for --ref\n' >&2
        usage >&2
        exit 1
      fi
      ref="$2"
      shift 2
      ;;
    --worktree-root)
      if [[ $# -lt 2 ]]; then
        printf 'Missing value for --worktree-root\n' >&2
        usage >&2
        exit 1
      fi
      worktree_root="$2"
      shift 2
      ;;
    --label)
      if [[ $# -lt 2 ]]; then
        printf 'Missing value for --label\n' >&2
        usage >&2
        exit 1
      fi
      audit_label="$2"
      audit_args+=("$1" "$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      audit_args+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$ref" ]]; then
  printf 'Missing required --ref\n' >&2
  usage >&2
  exit 1
fi

if [[ -z "$audit_label" ]]; then
  printf 'Missing required --label\n' >&2
  usage >&2
  exit 1
fi

resolved_commit="$(git -C "$REPO_ROOT" rev-parse --verify "$ref^{commit}")"
short_commit="$(git -C "$REPO_ROOT" rev-parse --short=8 "$resolved_commit")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
label_slug="$(slugify "$audit_label")"
if [[ -z "$label_slug" ]]; then
  label_slug="audit"
fi

mkdir -p "$worktree_root"
worktree_path="$worktree_root/harness-monitor-audit-${short_commit}-${timestamp}-${label_slug}"
audit_stdout_log="$(mktemp)"

cleanup() {
  local exit_code="$?"
  rm -f "$audit_stdout_log"
  if [[ -d "$worktree_path" ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

git -C "$REPO_ROOT" worktree add --detach "$worktree_path" "$resolved_commit"

audit_script_path="$worktree_path/apps/harness-monitor-macos/Scripts/run-instruments-audit.sh"
if [[ ! -x "$audit_script_path" ]]; then
  printf 'Audit script not found in worktree: %s\n' "$audit_script_path" >&2
  exit 1
fi

(
  cd "$worktree_path"
  mise trust
  "$audit_script_path" "${audit_args[@]}"
) 2>&1 | tee "$audit_stdout_log"

run_dir="$(awk -F'Artifacts written to ' '/Artifacts written to / {print $2}' "$audit_stdout_log" | tail -n 1)"
if [[ -z "$run_dir" ]]; then
  printf 'Unable to determine audit run directory from %s\n' "$audit_stdout_log" >&2
  exit 1
fi

PERF_CLI_BINARY="$APP_ROOT/Tools/HarnessMonitorPerf/.build/release/harness-monitor-perf"
"$PERF_CLI_BINARY" verify-manifest \
  --manifest "$run_dir/manifest.json" \
  --expected-commit "$resolved_commit"

printf 'Verified manifest provenance for %s\n' "$resolved_commit"
