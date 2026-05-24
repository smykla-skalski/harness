#!/bin/bash

# Xcode injects build settings into Run Script phases as environment variables.
# Standalone Swift CLI entrypoints warn when unknown SWIFT_* names leak through,
# so strip the Xcode-only debug-info settings before invoking them.
sanitize_xcode_only_swift_environment() {
  unset SWIFT_DEBUG_INFORMATION_FORMAT
  unset SWIFT_DEBUG_INFORMATION_VERSION
}

run_with_sanitized_xcode_only_swift_environment() {
  env \
    -u SWIFT_DEBUG_INFORMATION_FORMAT \
    -u SWIFT_DEBUG_INFORMATION_VERSION \
    "$@"
}
