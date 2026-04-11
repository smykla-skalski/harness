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

resolve_common_repo_root() {
  local common_git_dir
  common_git_dir="$(git -C "$REPO_ROOT" rev-parse --git-common-dir)"
  if [[ "$common_git_dir" != /* ]]; then
    common_git_dir="$REPO_ROOT/$common_git_dir"
  fi
  CDPATH='' cd -- "$common_git_dir/.." && pwd
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

COMMON_REPO_ROOT="$(resolve_common_repo_root)"

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

python3 - "$run_dir/manifest.json" "$resolved_commit" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
expected_commit = sys.argv[2]

if not manifest_path.exists():
    raise SystemExit(f"manifest.json not found at {manifest_path}")

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
git_info = manifest.get("git", {})
targets = manifest.get("targets", {})
build_provenance = manifest.get("build_provenance", {})
host = build_provenance.get("host", {})

errors: list[str] = []

if git_info.get("commit") != expected_commit:
    errors.append(
        f"manifest git.commit={git_info.get('commit')} does not match expected {expected_commit}"
    )
if git_info.get("dirty") is not False:
    errors.append(f"manifest git.dirty must be false, got {git_info.get('dirty')!r}")
if not git_info.get("workspace_fingerprint"):
    errors.append("manifest git.workspace_fingerprint is missing")
if host.get("embedded_commit") != expected_commit:
    errors.append(
        f"manifest host embedded_commit={host.get('embedded_commit')} does not match expected {expected_commit}"
    )
if host.get("embedded_dirty") not in ("false", False):
    errors.append(f"manifest host embedded_dirty must be false, got {host.get('embedded_dirty')!r}")
if not host.get("binary_sha256"):
    errors.append("manifest host binary_sha256 is missing")
if not targets.get("staged_host_bundle_id"):
    errors.append("manifest staged_host_bundle_id is missing")

if errors:
    raise SystemExit("\n".join(errors))
PY

printf 'Verified manifest provenance for %s\n' "$resolved_commit"
