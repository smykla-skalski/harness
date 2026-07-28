/// Canonical definition lives in `harness-protocol`: `ObserverState` (in
/// `state.rs`) needs this as a real crate dependency rather than a second
/// copy compiled in through this file's `#[path]` include from the daemon
/// facade. See `harness_protocol::observe`.
pub use harness_protocol::observe::IssueCategory;

/// Canonical definition lives in `harness-protocol`, alongside `IssueCategory`.
pub use harness_protocol::observe::{
    Confidence, FixSafety, IssueSeverity, MessageRole, SourceTool,
};
