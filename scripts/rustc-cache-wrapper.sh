#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

# Resolve sccache by absolute path, not PATH lookup. Cargo bakes the effective
# rustc invocation into its fingerprint - whether this wrapper resolves to
# `sccache rustc <args>` or plain `rustc <args>` changes the fingerprint and
# invalidates every cached crate the next time the other branch runs.
#
# `command -v sccache` depends on the caller's PATH. Xcode UI inherits launchd's
# PATH (which usually omits /opt/homebrew/bin), terminal `mise run` sees the
# full mise-augmented PATH. Without this absolute lookup the two contexts pick
# different branches and every cross-context build is cold.
for sccache_candidate in \
  "${SCCACHE_BIN:-}" \
  /opt/homebrew/bin/sccache \
  /usr/local/bin/sccache; do
  if [ -n "$sccache_candidate" ] && [ -x "$sccache_candidate" ]; then
    exec "$sccache_candidate" "$@"
  fi
done

exec "$@"
