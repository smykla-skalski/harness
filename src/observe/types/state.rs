/// Canonical definition lives in `harness-protocol`: `ObserverState` needs
/// to be a real crate dependency rather than a second copy compiled in
/// through this file's `#[path]` include from the daemon facade. See
/// `harness_protocol::observe`, which also carries the rest of this chain
/// (`OpenIssue`, `IssueAttempt`, `ActiveWorker`, `AgentObserveRecord`) that
/// this file never named directly even before the move.
pub use harness_protocol::observe::{Issue, ObserverState, OpenIssue};
#[cfg(test)]
pub use harness_protocol::observe::ActiveWorker;
