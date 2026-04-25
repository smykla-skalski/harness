#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/e2e/lib.sh
. "$SCRIPT_DIR/lib.sh"

DEFAULT_BEFORE_HOURS=24
BEFORE_HOURS="$DEFAULT_BEFORE_HOURS"
DRY_RUN=0

usage() {
  cat <<EOF >&2
usage: clean-recordings.sh [--before-hours <N>] [--dry-run]

Remove e2e triage run directories whose timestamp is older than N hours ago.
Runs from the last N hours are kept.

Supported directory name formats:
  YYYY-MM-DDTHH-MM-SSZ-<scenario>-<uuid>   (e.g. 2026-04-25T14-53-01Z-swarm-...)
  YYMMDDHHMMSS-<scenario>-<uuid>            (e.g. 260425145301-swarm-...)

Options:
  --before-hours <N>   Hours threshold (default: $DEFAULT_BEFORE_HOURS).
                       Dirs with a timestamp before (now - N hours) are removed.
  --dry-run            Print what would be removed without deleting anything.
EOF
  exit 64
}

# Detect date flavour once so helpers can call the right binary.
# GNU date (coreutils) accepts --version; BSD date does not.
if date --version >/dev/null 2>&1; then
  DATE_FLAVOR="gnu"
else
  DATE_FLAVOR="bsd"
fi

# cutoff_epoch <hours>
# Print the Unix epoch that is <hours> hours before now.
cutoff_epoch() {
  local hours="$1"
  if [[ "$DATE_FLAVOR" == "gnu" ]]; then
    date -d "${hours} hours ago" +%s
  else
    date -v-"${hours}H" +%s
  fi
}

# parse_iso_dash_epoch <YYYY-MM-DDTHH-MM-SSZ>
# Print Unix epoch for an ISO-with-dashes UTC timestamp, or return 1.
parse_iso_dash_epoch() {
  local slug="$1"
  if [[ "$DATE_FLAVOR" == "gnu" ]]; then
    # Replace the time-separator dashes with colons; the trailing Z signals UTC to GNU date.
    local iso="${slug:0:11}${slug:11:2}:${slug:14:2}:${slug:17:2}${slug:19}"
    date -d "$iso" +%s 2>/dev/null
  else
    # BSD date treats the parsed time as local unless TZ=UTC is set.
    TZ=UTC date -j -f '%Y-%m-%dT%H-%M-%SZ' "$slug" +%s 2>/dev/null
  fi
}

# parse_compact_epoch <YYMMDDHHMMSS>
# Print Unix epoch for a compact 12-digit UTC timestamp, or return 1.
parse_compact_epoch() {
  local slug="$1"
  if [[ "$DATE_FLAVOR" == "gnu" ]]; then
    # Expand 2-digit year to 4 digits; the trailing Z signals UTC to GNU date.
    local iso="20${slug:0:2}-${slug:2:2}-${slug:4:2}T${slug:6:2}:${slug:8:2}:${slug:10:2}Z"
    date -d "$iso" +%s 2>/dev/null
  else
    TZ=UTC date -j -f '%y%m%d%H%M%S' "$slug" +%s 2>/dev/null
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --before-hours)
      if [[ $# -lt 2 ]]; then usage; fi
      BEFORE_HOURS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

if ! [[ "$BEFORE_HOURS" =~ ^[0-9]+$ ]] || [[ "$BEFORE_HOURS" -lt 1 ]]; then
  printf 'error: --before-hours must be a positive integer, got: %s\n' "$BEFORE_HOURS" >&2
  exit 1
fi

REPO_ROOT="$(e2e_repo_root)"
RUNS_DIR="$REPO_ROOT/_artifacts/runs"

if [[ ! -d "$RUNS_DIR" ]]; then
  printf 'no runs directory found at %s\n' "$RUNS_DIR"
  exit 0
fi

CUTOFF_EPOCH="$(cutoff_epoch "$BEFORE_HOURS")"

removed=0
kept=0

while IFS= read -r -d '' entry; do
  dir_name="$(basename -- "$entry")"

  # Dir names start with one of two fixed-format timestamp slugs:
  #   YYYY-MM-DDTHH-MM-SSZ  (ISO-with-dashes, e.g. 2026-04-25T14-53-01Z)
  #   YYMMDDHHMMSS          (compact 12 digits,  e.g. 260425145301)
  dir_epoch=""
  if [[ "$dir_name" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z) ]]; then
    dir_epoch="$(parse_iso_dash_epoch "${BASH_REMATCH[1]}")" || true
  elif [[ "$dir_name" =~ ^([0-9]{12}) ]]; then
    dir_epoch="$(parse_compact_epoch "${BASH_REMATCH[1]}")" || true
  fi
  if [[ -z "$dir_epoch" ]]; then
    continue
  fi

  if [[ "$dir_epoch" -lt "$CUTOFF_EPOCH" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[dry-run] would remove: %s\n' "$dir_name"
    else
      printf 'removing: %s\n' "$dir_name"
      rm -rf -- "$entry"
    fi
    removed=$(( removed + 1 ))
  else
    kept=$(( kept + 1 ))
  fi
done < <(find "$RUNS_DIR" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '\ndry-run complete: %d would be removed, %d kept (threshold: %dh ago)\n' \
    "$removed" "$kept" "$BEFORE_HOURS"
else
  printf '\ndone: %d removed, %d kept (threshold: %dh ago)\n' \
    "$removed" "$kept" "$BEFORE_HOURS"
fi
