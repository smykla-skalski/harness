use std::collections::{HashMap, HashSet, VecDeque};
use std::ops::Index;

use crate::kernel::tooling::ToolContext;

use super::IssueCode;

/// Tracks occurrences of a deduplicated issue family.
#[derive(Debug, Clone)]
pub struct OccurrenceTracker {
    pub count: usize,
    pub last_seen_line: usize,
}

/// Record of a `tool_use` block, for correlating with `tool_result`.
#[derive(Debug, Clone)]
pub struct ToolUseRecord {
    pub tool: ToolContext,
}

/// Ordered bounded window of recent `tool_use` blocks.
#[derive(Debug, Clone, Default)]
pub struct ToolUseWindow {
    order: VecDeque<String>,
    records: HashMap<String, ToolUseRecord>,
}

impl ToolUseWindow {
    pub(crate) const LIMIT: usize = 100;

    pub fn insert(&mut self, tool_use_id: String, record: ToolUseRecord) {
        if self.records.contains_key(&tool_use_id) {
            self.order.retain(|existing| existing != &tool_use_id);
        }
        self.order.push_back(tool_use_id.clone());
        self.records.insert(tool_use_id, record);

        while self.order.len() > Self::LIMIT {
            if let Some(oldest) = self.order.pop_front() {
                self.records.remove(&oldest);
            }
        }
    }

    #[must_use]
    pub fn get(&self, tool_use_id: &str) -> Option<&ToolUseRecord> {
        self.records.get(tool_use_id)
    }

    #[must_use]
    #[cfg(test)]
    pub fn contains_key(&self, tool_use_id: &str) -> bool {
        self.records.contains_key(tool_use_id)
    }

    #[must_use]
    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.records.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }
}

impl Index<&str> for ToolUseWindow {
    type Output = ToolUseRecord;

    fn index(&self, index: &str) -> &Self::Output {
        &self.records[index]
    }
}

/// Mutable state carried across lines during a scan.
#[derive(Debug, Default)]
pub struct ScanState {
    /// Map `tool_use_id` to the `tool_use` block for correlating with `tool_result`.
    pub last_tool_uses: ToolUseWindow,
    /// Track file edit churn: path -> edit count.
    pub edit_counts: HashMap<String, usize>,
    /// Dedup key: (stable issue family, semantic fingerprint).
    pub seen_issues: HashSet<(IssueCode, String)>,
    /// Session start timestamp from the first event.
    pub session_start_timestamp: Option<String>,
    /// Occurrence tracking: (code, fingerprint) -> tracker.
    pub issue_occurrences: HashMap<(IssueCode, String), OccurrenceTracker>,
    /// Set when a source code file is edited via Write/Edit without a
    /// subsequent `git commit`. Cleared on commit detection.
    pub source_code_edited_without_commit: bool,
    /// Resources created via `harness apply` or `harness delete` in the
    /// current group. Entries are `(resource_kind, resource_name)` pairs
    /// extracted from `--manifest` path segments. Cleared when
    /// `harness report group` is called after checking for missing deletes.
    pub pending_resource_creates: HashSet<String>,
    /// Recent kubectl get/describe targets with their line numbers.
    /// Used to detect piecemeal queries against the same resource.
    /// Each entry is `(normalized_target, line_number)`.
    pub kubectl_query_targets: VecDeque<(String, usize)>,
    /// Whether `harness capture` was seen since the last `harness report group`.
    /// Set to `true` on capture, reset to `false` on group report. Starts
    /// `true` so the very first group does not trigger a false positive.
    pub seen_capture_since_last_group_report: bool,
    /// Whether at least one `harness report group` has been seen. Used to
    /// distinguish the first group (no preceding capture obligation) from
    /// subsequent groups.
    pub seen_any_group_report: bool,
    /// Agent ID when scanning in multi-agent orchestration context.
    pub agent_id: Option<String>,
    /// Agent role in the orchestration session.
    pub agent_role: Option<String>,
    /// Orchestration session ID when scanning across agents.
    pub orchestration_session_id: Option<String>,
}
