pub(crate) mod application;
// `classifier` lives in `harness-observe` now, alongside the `patterns` and
// text helpers it depends on; this facade keeps `crate::observe::classifier`
// resolving for watch.rs/scan/io.rs, same shape as `crate::infra`.
pub(crate) mod classifier {
    pub use harness_observe::classifier::*;
}
mod compare;
mod context_cmd;
mod doctor;
mod dump;
pub mod output;
mod scan;
pub(crate) mod session;
pub(crate) mod transport;
pub(crate) mod types;
mod watch;

#[cfg(test)]
mod tests;

pub use transport::{ObserveArgs, ObserveFilterArgs, ObserveMode, ObserveScanActionKind};
pub use types::{
    Confidence, FOCUS_PRESETS, FixSafety, FocusPreset, Issue, IssueCategory, IssueCode,
    IssueSeverity, MessageRole, ObserverState, OccurrenceTracker, OpenIssue, ScanState, SourceTool,
    ToolUseRecord, compute_issue_id,
};

pub(crate) use application::maintenance::{
    is_observer_conflict, load_observer_state, save_observer_state,
};
pub(crate) use harness_observe::{DUMP_TRUNCATE_LENGTH, MIN_DUMP_TEXT_LENGTH, truncate_at};
// classifier (now in harness-observe) was the only production caller;
// `redact_details` itself is still exercised by this crate's own tests below.
#[cfg(test)]
pub(crate) use harness_observe::redact_details;
