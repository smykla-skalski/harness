mod classification;
mod issue_code;
#[cfg(not(feature = "standalone-daemon"))]
mod presets;
mod state;
mod tracking;

pub use classification::{
    Confidence, FixSafety, IssueCategory, IssueSeverity, MessageRole, SourceTool,
};
pub use harness_observe::compute_issue_id;
pub use issue_code::IssueCode;
#[cfg(not(feature = "standalone-daemon"))]
pub use presets::{FOCUS_PRESETS, FocusPreset};
#[cfg(test)]
pub use state::ActiveWorker;
pub use state::{Issue, ObserverState, OpenIssue};
#[cfg(test)]
pub use tracking::ToolUseWindow;
pub use tracking::{OccurrenceTracker, ScanState, ToolUseRecord};

#[cfg(test)]
mod tests;
