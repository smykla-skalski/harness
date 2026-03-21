mod classification;
mod issue_code;
mod presets;
mod state;
mod tracking;

pub use classification::{
    Confidence, FixSafety, IssueCategory, IssueSeverity, MessageRole, SourceTool,
};
pub use issue_code::{IssueCode, compute_issue_id};
pub use presets::{FOCUS_PRESETS, FocusPreset};
#[cfg(test)]
pub use state::ActiveWorker;
pub use state::{CycleRecord, Issue, ObserverState, OpenIssue};
#[cfg(test)]
pub use tracking::ToolUseWindow;
pub use tracking::{OccurrenceTracker, ScanState, ToolUseRecord};

#[cfg(test)]
mod tests;
