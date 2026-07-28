/// Canonical definition lives in `harness-protocol`: `ScanState` needs
/// `harness_kernel::kernel::tooling::ToolContext` as a real crate dependency
/// rather than a second copy compiled in through this file's `#[path]`
/// include from the daemon facade. `OccurrenceTracker`, `ToolUseRecord`, and
/// `ToolUseWindow` move there too since they're part of the same tracking
/// chain. See `harness_protocol::observe`.
pub use harness_protocol::observe::{OccurrenceTracker, ScanState, ToolUseRecord, ToolUseWindow};
