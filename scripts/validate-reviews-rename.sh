#!/usr/bin/env bash
# Validator for the Dependencies → Reviews rename.
#
# Walks the repo + memory tree and flags any remaining feature-shaped
# "dependency" reference that is NOT on the allow-list in
# scripts/.rename-allow.txt.
#
# Exit codes:
#   0 — clean (no flagged matches)
#   1 — flagged matches present (printed to stdout)
#   2 — environment problem (rg not found, etc.)
#
# Usage: validate-reviews-rename.sh [--memory-root <path>]
#
# By default scans the repo root and the canonical memory tree at
# ~/.claude/projects/-Users-bart-smykla-konghq-com-Projects-github-com-smykla-skalski-harness/memory/

set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
ALLOW_FILE="$ROOT/scripts/.rename-allow.txt"
MEMORY_ROOT_DEFAULT="$HOME/.claude/projects/-Users-bart-smykla-konghq-com-Projects-github-com-smykla-skalski-harness/memory"
MEMORY_ROOT="$MEMORY_ROOT_DEFAULT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --memory-root) MEMORY_ROOT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: validate-reviews-rename.sh [--memory-root <path>]

Scans repo + memory tree for remaining Dependencies-feature references.
Compares each match against scripts/.rename-allow.txt patterns; flags
anything not on the allow-list.

Repo scan covers .rs .swift .toml .md .json .yaml .yml .sh files
under src/ apps/ scripts/ docs/ plus repo-root markdown.

Memory scan covers MEMORY.md + every .md file under memory root.
EOF
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v rg >/dev/null 2>&1; then
  echo "rg (ripgrep) is required" >&2
  exit 2
fi

# ----- Build the rejection regex -----
# Match any feature-shaped form we care about.
REJECT_REGEX='(Dependency|Dependencies|dependency_update|dependency-updates|DEPENDENCY_UPDATE|dependencyUpdate)'

# ----- Build the allow-list filter -----
# Read patterns from allow-file; each non-empty non-# line is an ERE pattern
# that, if it matches the full "file:line:col:matched_line" record, marks
# the match as legitimate.
declare -a ALLOW_PATTERNS=()
if [[ -f "$ALLOW_FILE" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    ALLOW_PATTERNS+=("$line")
  done < "$ALLOW_FILE"
fi

is_allowed() {
  local record="$1"
  local pat
  for pat in "${ALLOW_PATTERNS[@]}"; do
    if [[ "$record" =~ $pat ]]; then
      return 0
    fi
  done
  return 1
}

# ----- Scan the repo -----
REPO_PATHS=(
  "$ROOT/src"
  "$ROOT/apps"
  "$ROOT/scripts"
  "$ROOT/docs"
)

scan_repo() {
  local path
  for path in "${REPO_PATHS[@]}"; do
    [[ -d "$path" ]] || continue
    rg --no-heading --line-number --column \
       -e "$REJECT_REGEX" \
       --glob '*.rs' --glob '*.swift' --glob '*.toml' --glob '*.md' \
       --glob '*.json' --glob '*.yaml' --glob '*.yml' --glob '*.sh' \
       --glob '!target' --glob '!target/**' \
       --glob '!.build' --glob '!.build/**' \
       --glob '!DerivedData' --glob '!DerivedData/**' \
       --glob '!xcode-derived' --glob '!xcode-derived/**' \
       --glob '!xcode-derived-lanes' --glob '!xcode-derived-lanes/**' \
       --glob '!.git' --glob '!.git/**' \
       --glob '!node_modules' --glob '!node_modules/**' \
       "$path" 2>/dev/null || true
  done
  # Repo-root .md (CLAUDE.md, AGENTS.md, README.md, etc.)
  rg --no-heading --line-number --column \
     -e "$REJECT_REGEX" \
     --glob '*.md' \
     --max-depth 1 \
     "$ROOT" 2>/dev/null || true
}

scan_memory() {
  [[ -d "$MEMORY_ROOT" ]] || return 0
  rg --no-heading --line-number --column \
     -e "$REJECT_REGEX" \
     --glob '*.md' \
     "$MEMORY_ROOT" 2>/dev/null || true
}

# ----- Aggregate, filter, report -----
total_matches=0
allowed_matches=0
flagged_matches=0
declare -a FLAGGED=()

process_records() {
  local record
  while IFS= read -r record; do
    [[ -z "$record" ]] && continue
    total_matches=$((total_matches + 1))
    if is_allowed "$record"; then
      allowed_matches=$((allowed_matches + 1))
    else
      flagged_matches=$((flagged_matches + 1))
      FLAGGED+=("$record")
    fi
  done
}

process_records < <(scan_repo)
process_records < <(scan_memory)

if (( flagged_matches > 0 )); then
  printf 'FLAGGED %d matches not on allow-list:\n' "$flagged_matches"
  printf '  %s\n' "${FLAGGED[@]}"
  echo
fi
printf 'Total: %d  Allowed: %d  Flagged: %d\n' \
  "$total_matches" "$allowed_matches" "$flagged_matches"

if (( flagged_matches > 0 )); then
  exit 1
fi
exit 0
