#[derive(Debug, Clone)]
pub(crate) struct ObserveFilter {
    pub(crate) from_line: usize,
    pub(crate) from: Option<String>,
    pub(crate) focus: Option<String>,
    pub(crate) project_hint: Option<String>,
    pub(crate) json: bool,
    pub(crate) summary: bool,
    pub(crate) severity: Option<String>,
    pub(crate) category: Option<String>,
    pub(crate) exclude: Option<String>,
    pub(crate) fixable: bool,
    pub(crate) mute: Option<String>,
    pub(crate) until_line: Option<usize>,
    pub(crate) since_timestamp: Option<String>,
    pub(crate) until_timestamp: Option<String>,
    pub(crate) format: Option<String>,
    pub(crate) overrides: Option<String>,
    pub(crate) top_causes: Option<usize>,
    pub(crate) output: Option<String>,
    pub(crate) output_details: Option<String>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum ObserveActionKind {
    Cycle,
    Status,
    Resume,
    Verify,
    ResolveFrom,
    Compare,
    ListCategories,
    ListFocusPresets,
    Doctor,
    Mute,
    Unmute,
}

#[derive(Debug, Clone)]
pub(crate) enum ObserveRequest {
    Scan(ObserveScanRequest),
    Watch(ObserveWatchRequest),
    Dump(ObserveDumpRequest),
}

#[derive(Debug, Clone)]
pub(crate) struct ObserveScanRequest {
    pub(crate) session_id: Option<String>,
    pub(crate) action: Option<ObserveActionKind>,
    pub(crate) issue_id: Option<String>,
    pub(crate) since_line: Option<usize>,
    pub(crate) value: Option<String>,
    pub(crate) range_a: Option<String>,
    pub(crate) range_b: Option<String>,
    pub(crate) codes: Option<String>,
    pub(crate) filter: ObserveFilter,
}

#[derive(Debug, Clone)]
pub(crate) struct ObserveWatchRequest {
    pub(crate) session_id: String,
    pub(crate) poll_interval: u64,
    pub(crate) timeout: u64,
    pub(crate) filter: ObserveFilter,
}

#[derive(Debug, Clone)]
pub(crate) struct ObserveDumpRequest {
    pub(crate) session_id: String,
    pub(crate) context_line: Option<usize>,
    pub(crate) context_window: usize,
    pub(crate) from_line: Option<usize>,
    pub(crate) to_line: Option<usize>,
    pub(crate) filter: Option<String>,
    pub(crate) role: Option<String>,
    pub(crate) tool_name: Option<String>,
    pub(crate) raw_json: bool,
    pub(crate) project_hint: Option<String>,
}
