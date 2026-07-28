mod classification;
mod issue_code;
mod presets;
mod state;
mod tracking;

pub use crate::compute_issue_id;
pub use classification::{
    Confidence, FixSafety, IssueCategory, IssueSeverity, MessageRole, SourceTool,
};
pub use issue_code::IssueCode;
pub use presets::{FOCUS_PRESETS, FocusPreset};
// Unlike this crate's own `#[cfg(test)]` items, these can't stay test-gated:
// a `#[cfg(test)]` item never survives crossing a crate boundary, since a
// downstream crate's own test build never compiles *this* crate with
// `cfg(test)`. `harness_protocol::observe` already exports both unconditionally,
// so re-exporting them the same way here just matches their real visibility.
pub use state::{ActiveWorker, Issue, ObserverState, OpenIssue};
pub use tracking::{OccurrenceTracker, ScanState, ToolUseRecord, ToolUseWindow};

#[cfg(test)]
mod tests;
