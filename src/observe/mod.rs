pub(crate) mod application;
mod doctor;
// `ObserveFilterArgs`/`ObserveMode`/`ObserveScanActionKind` moved to
// `harness-observe`; `ObserveArgs` and the CLI-args-to-request glue stay here
// since they build this crate's own `application::ObserveRequest`.
pub(crate) mod transport;
pub(crate) mod types {
    pub use harness_observe::types::*;
}

pub use transport::{ObserveArgs, ObserveFilterArgs, ObserveMode, ObserveScanActionKind};
pub use types::{
    Confidence, FOCUS_PRESETS, FixSafety, FocusPreset, Issue, IssueCategory, IssueCode,
    IssueSeverity, MessageRole, ObserverState, OccurrenceTracker, OpenIssue, ScanState, SourceTool,
    ToolUseRecord, compute_issue_id,
};
