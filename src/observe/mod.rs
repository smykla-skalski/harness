pub(crate) mod application;
pub(crate) mod classifier;
mod compare;
mod context_cmd;
mod doctor;
mod dump;
pub mod output;
pub(crate) mod patterns;
mod scan;
pub(crate) mod session;
mod text;
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
pub(crate) use text::{
    DUMP_TRUNCATE_LENGTH, MIN_DUMP_TEXT_LENGTH, redact_details, truncate_at, truncate_details,
};
