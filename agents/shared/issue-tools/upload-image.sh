#!/usr/bin/env bash
#
# Upload one or more local images to GitHub via the Git Data API.
# Outputs one markdown image reference per file on stdout.
#
# Before uploading, each image is validated:
#   - file must exist and be readable
#   - file must be a supported image format (png, jpg, jpeg, gif, webp, svg)
#   - files over MAX_SIZE_BYTES (default 5MB) are auto-optimized via sips
#
# Usage:
#   upload-image.sh [--repo owner/name] [--max-size BYTES] <file> [<file> ...]
#
# Requirements: gh (authenticated), base64, curl, jq, sips (macOS built-in)

set -euo pipefail

MAX_SIZE_BYTES="${MAX_SIZE_BYTES:-5242880}"  # 5MB default

usage() {
  cat <<'EOF'
usage: upload-image.sh [--repo owner/name] [--max-size BYTES] <file> [<file> ...]

Uploads local image files into an orphan Git commit kept alive by a hidden ref,
then prints markdown image references that can be embedded directly in a GitHub
issue body.

Images over --max-size (default 5MB) are automatically resized to fit under the
limit using sips. Optimized copies are placed alongside the original with an
"-optimized" suffix and cleaned up after upload.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Supported image extensions (lowercase)
is_supported_format() {
  local ext="${1##*.}"
  ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    png|jpg|jpeg|gif|webp|svg) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns file size in bytes, portable across macOS and Linux
file_size_bytes() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || wc -c < "$1" | tr -d ' '
}

# Optimize an image to fit under MAX_SIZE_BYTES using sips.
# Returns the path to the optimized file (may be the original if already small enough).
optimize_image() {
  local file="$1"
  local size
  size="$(file_size_bytes "$file")"

  if [[ "$size" -le "$MAX_SIZE_BYTES" ]]; then
    printf '%s' "$file"
    return 0
  fi

  local ext="${file##*.}"
  ext_lower="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"

  # SVGs can't be rasterized/resized by sips - just warn and pass through
  if [[ "$ext_lower" == "svg" ]]; then
    echo "warning: $file is ${size} bytes (over limit) but SVG cannot be auto-optimized" >&2
    printf '%s' "$file"
    return 0
  fi

  if ! command -v sips >/dev/null 2>&1; then
    echo "warning: $file is ${size} bytes (over limit) but sips is not available for auto-optimization" >&2
    printf '%s' "$file"
    return 0
  fi

  local stem="${file%.*}"
  local optimized="${stem}-optimized.${ext}"
  cp "$file" "$optimized"
  _cleanup_files+=("$optimized")

  # Iteratively halve the longest dimension until under the size limit.
  # Each pass reduces pixel count by ~75% which typically halves file size.
  local attempts=0
  local max_attempts=5
  while [[ "$(file_size_bytes "$optimized")" -gt "$MAX_SIZE_BYTES" && "$attempts" -lt "$max_attempts" ]]; do
    local current_width current_height
    current_width="$(sips -g pixelWidth "$optimized" 2>/dev/null | tail -1 | awk '{print $2}')"
    current_height="$(sips -g pixelHeight "$optimized" 2>/dev/null | tail -1 | awk '{print $2}')"

    local new_width=$((current_width / 2))
    local new_height=$((current_height / 2))

    # Don't shrink below 200px on either dimension
    if [[ "$new_width" -lt 200 || "$new_height" -lt 200 ]]; then
      echo "warning: $file cannot be optimized further without going below 200px" >&2
      break
    fi

    sips --resampleHeightWidth "$new_height" "$new_width" "$optimized" >/dev/null 2>&1
    attempts=$((attempts + 1))
  done

  local final_size
  final_size="$(file_size_bytes "$optimized")"
  if [[ "$final_size" -gt "$MAX_SIZE_BYTES" ]]; then
    echo "warning: $file optimized to ${final_size} bytes but still over ${MAX_SIZE_BYTES} limit" >&2
  else
    echo "info: $file optimized from ${size} to ${final_size} bytes" >&2
  fi

  printf '%s' "$optimized"
}

# Track files to clean up on exit
_cleanup_files=()
cleanup() {
  for f in "${_cleanup_files[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup EXIT

repo=""
files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      repo="$2"
      shift 2
      ;;
    --max-size)
      [[ $# -ge 2 ]] || die "--max-size requires a value"
      MAX_SIZE_BYTES="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown flag: $1"
      ;;
    *)
      files+=("$1")
      shift
      ;;
  esac
done

while [[ $# -gt 0 ]]; do
  files+=("$1")
  shift
done

[[ ${#files[@]} -gt 0 ]] || {
  usage >&2
  exit 1
}

gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || {
    die "could not determine repository - run from inside a git repo with a GitHub remote or pass --repo"
  }
fi

# Validate all files before uploading any
for file in "${files[@]}"; do
  [[ -e "$file" ]] || die "file not found: $file"
  [[ -f "$file" ]] || die "not a regular file: $file"
  [[ -r "$file" ]] || die "file not readable: $file"
  is_supported_format "$file" || die "unsupported image format: $file (supported: png, jpg, jpeg, gif, webp, svg)"
done

reserve_upload_name() {
  local original="$1"
  local stem="$original"
  local ext=""
  local candidate="$original"
  local counter=2

  if [[ "$original" == *.* && "$original" != .* ]]; then
    stem="${original%.*}"
    ext=".${original##*.}"
  fi

  while [[ "$used_names" == *$'\n'"$candidate"$'\n'* ]]; do
    candidate="${stem}-${counter}${ext}"
    counter=$((counter + 1))
  done

  used_names+="${candidate}"$'\n'
  printf '%s\n' "$candidate"
}

urlencode() {
  local string="$1"
  local i
  local char
  for (( i = 0; i < ${#string}; i++ )); do
    char="${string:i:1}"
    case "$char" in
      [a-zA-Z0-9._~-]) printf '%s' "$char" ;;
      *) printf '%%%02X' "'$char" ;;
    esac
  done
}

tree_entries='[]'
used_names=$'\n'
source_names=()
upload_names=()

# Optimize images that exceed the size limit, then create blobs
optimized_files=()
for file in "${files[@]}"; do
  optimized="$(optimize_image "$file")"
  optimized_files+=("$optimized")

  source_name="$(basename "$file")"
  upload_name="$(reserve_upload_name "$source_name")"

  blob_sha="$(
    gh api "repos/${repo}/git/blobs" \
      -f content="$(base64 < "$optimized" | tr -d '\n')" \
      -f encoding=base64 \
      --jq '.sha'
  )" || die "failed to create blob for $file"

  tree_entries="$(
    printf '%s' "$tree_entries" | jq \
      --arg path "$upload_name" \
      --arg sha "$blob_sha" \
      '. + [{"path": $path, "mode": "100644", "type": "blob", "sha": $sha}]'
  )"

  source_names+=("$source_name")
  upload_names+=("$upload_name")
done

tree_sha="$(
  printf '%s' "$tree_entries" | jq '{tree: .}' | gh api "repos/${repo}/git/trees" --input - --jq '.sha'
)" || die "failed to create tree"

commit_sha="$(
  printf '{"message":"issue attachment","tree":"%s","parents":[]}' "$tree_sha" \
    | gh api "repos/${repo}/git/commits" --input - --jq '.sha'
)" || die "failed to create commit"

gh api "repos/${repo}/git/refs" \
  -f ref="refs/uploads/issue-images/${commit_sha}" \
  -f sha="$commit_sha" \
  --silent >/dev/null 2>&1 || die "failed to create ref"

exit_code=0

for i in "${!files[@]}"; do
  source_name="${source_names[$i]}"
  upload_name="${upload_names[$i]}"
  encoded_name="$(urlencode "$upload_name")"
  url="https://github.com/${repo}/blob/${commit_sha}/${encoded_name}?raw=true"
  status="$(curl -sL -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"

  if [[ "$status" != "200" ]]; then
    echo "warning: upload verification failed for ${source_name} (HTTP ${status:-000})" >&2
    exit_code=1
  fi

  alt_text="${source_name%.*}"
  alt_text="${alt_text//-/ }"
  alt_text="${alt_text//_/ }"
  printf '![%s](%s)\n' "$alt_text" "$url"
done

exit "$exit_code"
