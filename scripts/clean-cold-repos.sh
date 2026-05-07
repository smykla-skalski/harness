#!/usr/bin/env bash
# T3 deletion of cold non-harness repos under ~/Projects/github.com.
#
# For each candidate root directory, recursively finds every git repo and
# performs safety checks before allowing deletion:
#   - dirty working tree (uncommitted changes)
#   - unpushed commits (local ahead of upstream)
#   - missing upstream tracking branch
#   - submodules with their own dirty/unpushed state
# Any failed check causes the parent root to be skipped entirely so no work
# is lost. Reports skipped repos with reason.
#
# Default scope (cold repos surfaced during disk audit):
#   ~/Projects/github.com/kong
#   ~/Projects/github.com/bartsmykla
#   ~/Projects/github.com/smykla-skalski/klab
#   ~/Projects/github.com/smykla-skalski/kubernetes-manifests
#   ~/Projects/github.com/JetBrains
set -euo pipefail

DRY_RUN=0
SKIP_VENDORED=0
ROOTS=()
# Path fragments that indicate a vendored / package-manager-managed checkout
# whose dirty/no-upstream state is expected (cargo, go modules, npm git deps).
VENDORED_FRAGMENTS=(
  '/tmp/cargo/git/checkouts/'
  '/.cargo/git/checkouts/'
  '/target/cargo-cache/'
  '/vendor/cache/'
  '/go/pkg/mod/cache/'
  '/node_modules/'
)

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --skip-vendored) SKIP_VENDORED=1 ;;
    --root) ROOTS+=("$2"); shift ;;
    -h|--help) cat <<EOF
Usage: $(basename "$0") [--dry-run] [--skip-vendored] [--root PATH ...]

  --skip-vendored  Ignore git repos under cargo/go/npm vendored paths
                   (tmp/cargo/git/checkouts, .cargo/git/checkouts,
                   go/pkg/mod/cache, node_modules) - their dirty state is
                   normal and not user work.

Default roots if --root is not given:
  \$HOME/Projects/github.com/kong
  \$HOME/Projects/github.com/bartsmykla
  \$HOME/Projects/github.com/smykla-skalski/klab
  \$HOME/Projects/github.com/smykla-skalski/kubernetes-manifests
  \$HOME/Projects/github.com/JetBrains
EOF
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

if (( ${#ROOTS[@]} == 0 )); then
  ROOTS=(
    "$HOME/Projects/github.com/kong"
    "$HOME/Projects/github.com/bartsmykla"
    "$HOME/Projects/github.com/smykla-skalski/klab"
    "$HOME/Projects/github.com/smykla-skalski/kubernetes-manifests"
    "$HOME/Projects/github.com/JetBrains"
  )
fi

bytes_to_human() {
  local kb=${1:-0}
  if (( kb < 1024 )); then printf '%dK' "$kb"
  elif (( kb < 1024**2 )); then printf '%.1fM' "$(bc -l <<<"$kb/1024")"
  else printf '%.1fG' "$(bc -l <<<"$kb/1024/1024")"
  fi
}

path_size_kb() {
  [[ -e "$1" ]] || { echo 0; return; }
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

disk_free_g() {
  df -k / | awk 'NR==2 {printf "%.1fG free of %.1fG (%s used)", $4/1024/1024, $2/1024/1024, $5}'
}

is_vendored_path() {
  local path=$1
  local frag
  for frag in "${VENDORED_FRAGMENTS[@]}"; do
    case "$path" in
      *"$frag"*) return 0 ;;
    esac
  done
  return 1
}

# Echo a list of unsafe-to-delete reasons; empty = safe.
audit_repo() {
  local repo=$1
  local out=()
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  if (( SKIP_VENDORED )) && is_vendored_path "$repo"; then
    return 0
  fi
  if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    out+=("dirty working tree")
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    out+=("unpushed branch: $line")
  done < <(git -C "$repo" for-each-ref --format='%(refname:short) %(upstream:short) %(upstream:track)' refs/heads 2>/dev/null \
            | awk 'NF==1 {print $1" (no upstream)"} /\[ahead/ {print $0}')
  while IFS= read -r -d '' sub_git; do
    sub_repo=$(dirname "$sub_git")
    [[ "$sub_repo" == "$repo" ]] && continue
    if (( SKIP_VENDORED )) && is_vendored_path "$sub_repo"; then
      continue
    fi
    if [[ -n "$(git -C "$sub_repo" status --porcelain 2>/dev/null)" ]]; then
      out+=("submodule dirty: ${sub_repo#"$repo"/}")
    fi
  done < <(find "$repo" -name '.git' -type d -print0 2>/dev/null)
  printf '%s\n' "${out[@]}"
}

printf '== clean-cold-repos =='
(( DRY_RUN )) && printf ' (dry-run)'
printf '\nbefore: %s\n' "$(disk_free_g)"

declare -A SKIP_REASONS
TOTAL_RECLAIMED_KB=0
DELETED_ROOTS=()

for root in "${ROOTS[@]}"; do
  printf '\n--- %s ---\n' "$root"
  if [[ ! -d "$root" ]]; then
    printf '  (absent, skip)\n'
    continue
  fi
  size_kb=$(path_size_kb "$root")
  printf '  size: %s\n' "$(bytes_to_human "$size_kb")"

  unsafe_lines=()
  while IFS= read -r -d '' git_dir; do
    repo=$(dirname "$git_dir")
    rel=${repo#"$root"/}
    [[ "$repo" == "$root" ]] && rel="(root)"
    while IFS= read -r reason; do
      [[ -n "$reason" ]] || continue
      unsafe_lines+=("$rel: $reason")
    done < <(audit_repo "$repo")
  done < <(find "$root" -name '.git' -type d -print0 2>/dev/null)

  if (( ${#unsafe_lines[@]} > 0 )); then
    printf '  SKIP — unsafe to delete:\n'
    for l in "${unsafe_lines[@]}"; do
      printf '    - %s\n' "$l"
    done
    SKIP_REASONS["$root"]="${#unsafe_lines[@]} blockers"
    continue
  fi

  printf '  clean — every repo is committed and pushed\n'
  if (( DRY_RUN )); then
    printf '  (dry-run) would rm -rf %s\n' "$root"
  else
    printf '  rm -rf %s\n' "$root"
    rm -rf -- "$root"
  fi
  TOTAL_RECLAIMED_KB=$((TOTAL_RECLAIMED_KB + size_kb))
  DELETED_ROOTS+=("$root")
done

printf '\n== summary ==\n'
if (( ${#DELETED_ROOTS[@]} > 0 )); then
  printf 'deleted roots: %d\n' "${#DELETED_ROOTS[@]}"
  for d in "${DELETED_ROOTS[@]}"; do printf '  + %s\n' "$d"; done
fi
if (( ${#SKIP_REASONS[@]} > 0 )); then
  printf 'skipped roots: %d\n' "${#SKIP_REASONS[@]}"
  for r in "${!SKIP_REASONS[@]}"; do printf '  ! %s — %s\n' "$r" "${SKIP_REASONS[$r]}"; done
fi
printf 'reclaimed (sum of deleted root sizes): %s\n' "$(bytes_to_human "$TOTAL_RECLAIMED_KB")"
printf 'after:  %s\n' "$(disk_free_g)"
(( DRY_RUN )) && printf '(dry-run; nothing was deleted)\n'
exit 0
