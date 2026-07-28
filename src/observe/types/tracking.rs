/// Canonical definition lives in `harness-protocol`: `ScanState` needs
/// `harness_kernel::kernel::tooling::ToolContext` as a real crate dependency
/// rather than a second copy compiled in through this file's `#[path]`
/// include from the daemon facade. See `harness_protocol::observe`, which
/// also carries the rest of this chain (`OccurrenceTracker`, `ToolUseRecord`,
/// `ToolUseWindow`) that this file never named directly even before the move.
pub use harness_protocol::observe::{OccurrenceTracker, ScanState, ToolUseRecord};
#[cfg(test)]
pub use harness_protocol::observe::ToolUseWindow;
