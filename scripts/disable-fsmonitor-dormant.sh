#!/usr/bin/env bash
# Set `core.fsmonitor=false` per-repo on dormant git repos so they stop
# spawning fsmonitor--daemon processes on `git status`.
#
# Why this exists: the user's global ~/.gitconfig has `core.fsmonitor=true`,
# which means every repo eagerly spawns a fsmonitor daemon the first time
# anything reads the index. With ~160 repos on disk, the daemon count
# trends upward by dozens per week. clean-stale-fsmonitor.sh kills daemons
# whose repos are dormant, but the next `git status` respawns them.
# Setting `core.fsmonitor=false` *locally* on a dormant repo overrides the
# global value so no daemon ever spawns there until the user manually
# re-enables it.
#
# "Dormant" iff neither HEAD nor FETCH_HEAD has been touched in the last
# --days days (default 30). The user can override --days for a more
# aggressive sweep (--days 90) or a more conservative one (--days 7).
#
# Safety: dry-run by default. Pass --apply to actually call
# `git config --local core.fsmonitor false`. Never disables anything in
# a path matching --exclude (defaults cover harness/kuma/kong-mesh/plugins/
# dotfiles/codex-home).
set -uo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --days N         Threshold in days for "dormant" (default: 30). Repos
                   whose HEAD and FETCH_HEAD are both older than N days
                   become candidates.
  --apply          Actually run \`git config --local core.fsmonitor false\`
                   on each dormant repo (default: dry-run, report only).
  --root PATH      Add a root directory to scan (repeatable). Defaults to
                   ~/Projects/github.com, ~/Shared/codex-home,
                   ~/.claude/plugins/marketplaces, and the dotfiles repo.
  --exclude PAT    Skip any candidate whose .git path contains PAT
                   (repeatable; substring match). Defaults to harness,
                   kumahq/kuma, kong/kong-mesh, plugins/marketplaces,
                   .dotfiles, Shared/codex-home, .github.
  --max-depth N    find -maxdepth for .git discovery (default 4). Raise
                   only if you stash repos under deeply nested category
                   directories.
  -h, --help       Show this help.
EOF
}

DAYS=30
APPLY=0
declare -a ROOTS=()
declare -a EXCLUDES=()
MAX_DEPTH=4
HAVE_USER_ROOTS=0
HAVE_USER_EXCLUDES=0

while (($#)); do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --root) ROOTS+=("$2"); HAVE_USER_ROOTS=1; shift 2 ;;
    --exclude) EXCLUDES+=("$2"); HAVE_USER_EXCLUDES=1; shift 2 ;;
    --max-depth) MAX_DEPTH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# Defaults survive the explicit override pattern: user-supplied --root/--exclude
# replace the defaults entirely; otherwise the standard list applies.
if (( HAVE_USER_ROOTS == 0 )); then
  ROOTS=(
    "$HOME/Projects/github.com"
    "$HOME/Shared/codex-home"
    "$HOME/.claude/plugins/marketplaces"
    "$HOME/Projects/github.com/smykla-skalski/.dotfiles"
  )
fi
if (( HAVE_USER_EXCLUDES == 0 )); then
  EXCLUDES=(
    "/smykla-skalski/harness/"
    "/kumahq/kuma/"
    "/kong/kong-mesh/"
    "/plugins/marketplaces/"
    "/.dotfiles/"
    "/Shared/codex-home/"
    "/smykla-skalski/.github/"
  )
fi

[[ "$DAYS" =~ ^[0-9]+$ ]] || { printf 'invalid --days value: %s\n' "$DAYS" >&2; exit 2; }
[[ "$MAX_DEPTH" =~ ^[0-9]+$ ]] || { printf 'invalid --max-depth value: %s\n' "$MAX_DEPTH" >&2; exit 2; }

# Per-repo lookup of `git config --local core.fsmonitor`. Reading the file
# directly avoids forking git per repo (faster on 200+ candidates) but
# still has to handle the "value spans multiple words / quoted / blank"
# corner. The only values we care about are the literal tokens `true` and
# `false`; anything else (an absolute path to a hook program, unset, etc.)
# is treated as "we don't know -- skip".
local_fsmonitor_value() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 1
  /usr/bin/awk '
    /^\[/ {
      in_core = ($0 ~ /^\[core\]/)
      next
    }
    in_core && /^[[:space:]]*fsmonitor[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      print
      exit
    }
  ' "$cfg"
}

is_excluded() {
  local path="$1"
  local pat
  for pat in "${EXCLUDES[@]}"; do
    if [[ "$path" == *"$pat"* ]]; then
      return 0
    fi
  done
  return 1
}

# Print a file's modification time as Unix seconds. BSD stat uses -f while
# GNU stat uses -c; validate the BSD-shaped result before accepting it because
# GNU stat -f can emit filesystem details even though that invocation fails.
file_mtime() {
  local path="$1"
  local m

  m="$(/usr/bin/stat -f '%m' "$path" 2>/dev/null || true)"
  if [[ "$m" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$m"
    return 0
  fi

  m="$(/usr/bin/stat -c '%Y' "$path" 2>/dev/null || true)"
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$m"
}

# Returns days-since-most-recent of HEAD/FETCH_HEAD. Empty if neither
# exists.
days_since_activity() {
  local gitdir="$1"
  local mtime=0 f m now days
  for f in "$gitdir/HEAD" "$gitdir/FETCH_HEAD"; do
    if [[ -e "$f" ]]; then
      if m="$(file_mtime "$f")" && (( m > mtime )); then
        mtime=$m
      fi
    fi
  done
  (( mtime > 0 )) || return 1
  now="$(/bin/date +%s)"
  days=$(( (now - mtime) / 86400 ))
  printf '%d\n' "$days"
}

declare -a DORMANT_GITDIRS=()
total_scanned=0
already_disabled=0
excluded=0
active=0
no_activity_signal=0

for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r gitdir; do
    [[ -f "$gitdir/config" ]] || continue
    total_scanned=$((total_scanned + 1))
    if is_excluded "$gitdir"; then
      excluded=$((excluded + 1))
      continue
    fi
    local_val="$(local_fsmonitor_value "$gitdir/config")"
    if [[ "$local_val" == "false" ]]; then
      already_disabled=$((already_disabled + 1))
      continue
    fi
    if ! days="$(days_since_activity "$gitdir")"; then
      no_activity_signal=$((no_activity_signal + 1))
      continue
    fi
    if (( days <= DAYS )); then
      active=$((active + 1))
      continue
    fi
    DORMANT_GITDIRS+=("$gitdir")
    printf '  · dormant   gitdir=%s days=%d\n' "$gitdir" "$days"
  done < <(/usr/bin/find "$root" -maxdepth "$MAX_DEPTH" -type d -name '.git' 2>/dev/null)
done

dormant_count=${#DORMANT_GITDIRS[@]}

printf '\nscanned=%d active=%d already_disabled=%d excluded=%d no_signal=%d dormant=%d\n' \
  "$total_scanned" "$active" "$already_disabled" "$excluded" "$no_activity_signal" "$dormant_count"

if (( dormant_count == 0 )); then
  printf 'No dormant repos with effective fsmonitor=true found at threshold %d days.\n' "$DAYS"
  exit 0
fi

if (( APPLY == 0 )); then
  printf '\nDry-run: would set core.fsmonitor=false on %d dormant repo(s). Re-run with --apply to do it.\n' \
    "$dormant_count"
  exit 0
fi

# Use `git config --file <gitdir>/config` instead of `--local`. Targeting
# the file directly avoids `git config --local`'s "must be inside a real
# git repo" check, which trips on bare or partially-initialized gitdirs
# (the fake fixtures in our tests, certain submodule layouts, etc.). The
# semantics are identical: the local config is exactly that file.
applied=0
failed=0
for gitdir in "${DORMANT_GITDIRS[@]}"; do
  if git config --file "$gitdir/config" core.fsmonitor false 2>/dev/null; then
    applied=$((applied + 1))
    printf '  set false: %s\n' "$gitdir"
  else
    failed=$((failed + 1))
    printf '  FAILED:    %s\n' "$gitdir" >&2
  fi
done

printf 'applied=%d failed=%d total=%d\n' "$applied" "$failed" "$dormant_count"
