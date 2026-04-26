#!/bin/bash
set -eu

# Strips Gatekeeper xattrs from a built UI test bundle and any associated
# *-Runner.app harness; wired as a Run Script post-build phase on the UI test
# targets.

if [ "${XCODE_RUNNING_FOR_PREVIEWS:-}" = "1" ] || [[ "${BUILD_DIR:-}" == *"/Previews/"* ]]; then
  exit 0
fi

strip_attrs() {
  local target_path="$1"
  if [ -e "$target_path" ]; then
    /usr/bin/xattr -dr com.apple.provenance "$target_path" 2>/dev/null || true
    /usr/bin/xattr -dr com.apple.quarantine "$target_path" 2>/dev/null || true
  fi
}

strip_attrs "$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

for runner in "$BUILT_PRODUCTS_DIR"/*-Runner.app; do
  if [ -e "$runner" ]; then
    strip_attrs "$runner"
  fi
done

if [ -n "${SCRIPT_OUTPUT_FILE_0:-}" ]; then
  /bin/mkdir -p "$(dirname "$SCRIPT_OUTPUT_FILE_0")"
  /usr/bin/touch "$SCRIPT_OUTPUT_FILE_0"
fi
