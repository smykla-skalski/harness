use harness_protocol::agent::HookAgent;

use crate::transport::{ObserveFilterArgs, ObserveScanActionKind};

#[derive(Debug, Clone)]
pub struct ObserveFilter {
    pub from_line: usize,
    pub from: Option<String>,
    pub focus: Option<String>,
    pub project_hint: Option<String>,
    pub json: bool,
    pub summary: bool,
    pub severity: Option<String>,
    pub category: Option<String>,
    pub exclude: Option<String>,
    pub fixable: bool,
    pub mute: Option<String>,
    pub until_line: Option<usize>,
    pub since_timestamp: Option<String>,
    pub until_timestamp: Option<String>,
    pub format: Option<String>,
    pub overrides: Option<String>,
    pub top_causes: Option<usize>,
    pub output: Option<String>,
    pub output_details: Option<String>,
    pub agent: Option<HookAgent>,
    pub observe_id: String,
}

// The root crate's own `build_filter` covers the CLI path, which carries a
// real `--agent`/`--observe-id`; this impl exists for this crate's own tests,
// which only need the shared-ledger defaults.
impl From<ObserveFilterArgs> for ObserveFilter {
    fn from(value: ObserveFilterArgs) -> Self {
        Self {
            from_line: value.from_line,
            from: value.from,
            focus: value.focus,
            project_hint: value.project_hint,
            json: value.json,
            summary: value.summary,
            severity: value.severity,
            category: value.category,
            exclude: value.exclude,
            fixable: value.fixable,
            mute: value.mute,
            until_line: value.until_line,
            since_timestamp: value.since_timestamp,
            until_timestamp: value.until_timestamp,
            format: value.format,
            overrides: value.overrides,
            top_causes: value.top_causes,
            output: value.output,
            output_details: value.output_details,
            agent: None,
            observe_id: "project-default".to_string(),
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub enum ObserveActionKind {
    Cycle,
    Status,
    Resume,
    Verify,
    ResolveFrom,
    Compare,
    ListCategories,
    ListFocusPresets,
    Mute,
    Unmute,
}

impl From<ObserveScanActionKind> for ObserveActionKind {
    fn from(value: ObserveScanActionKind) -> Self {
        match value {
            ObserveScanActionKind::Cycle => Self::Cycle,
            ObserveScanActionKind::Status => Self::Status,
            ObserveScanActionKind::Resume => Self::Resume,
            ObserveScanActionKind::Verify => Self::Verify,
            ObserveScanActionKind::ResolveFrom => Self::ResolveFrom,
            ObserveScanActionKind::Compare => Self::Compare,
            ObserveScanActionKind::ListCategories => Self::ListCategories,
            ObserveScanActionKind::ListFocusPresets => Self::ListFocusPresets,
            ObserveScanActionKind::Mute => Self::Mute,
            ObserveScanActionKind::Unmute => Self::Unmute,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ObserveScanRequest {
    pub session_id: Option<String>,
    pub action: Option<ObserveActionKind>,
    pub issue_id: Option<String>,
    pub since_line: Option<usize>,
    pub value: Option<String>,
    pub range_a: Option<String>,
    pub range_b: Option<String>,
    pub codes: Option<String>,
    pub filter: ObserveFilter,
}

#[derive(Debug, Clone)]
pub struct ObserveWatchRequest {
    pub session_id: String,
    pub poll_interval: u64,
    pub timeout: u64,
    pub filter: ObserveFilter,
}

#[derive(Debug, Clone)]
pub struct ObserveDumpRequest {
    pub session_id: String,
    pub context_line: Option<usize>,
    pub context_window: usize,
    pub from_line: Option<usize>,
    pub to_line: Option<usize>,
    pub filter: Option<String>,
    pub role: Option<String>,
    pub tool_name: Option<String>,
    pub raw_json: bool,
    pub project_hint: Option<String>,
    pub agent: Option<HookAgent>,
}
