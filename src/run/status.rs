use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io;

use super::{GroupVerdict, Verdict};

/// Counts of passed, failed, and skipped groups in a run.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct RunCounts {
    #[serde(default)]
    pub passed: u32,
    #[serde(default)]
    pub failed: u32,
    #[serde(default)]
    pub skipped: u32,
}

impl RunCounts {
    pub fn increment(&mut self, verdict: GroupVerdict) {
        match verdict {
            GroupVerdict::Pass => self.passed += 1,
            GroupVerdict::Fail => self.failed += 1,
            GroupVerdict::Skip => self.skipped += 1,
        }
    }

    pub fn decrement(&mut self, verdict: GroupVerdict) {
        match verdict {
            GroupVerdict::Pass => self.passed = self.passed.saturating_sub(1),
            GroupVerdict::Fail => self.failed = self.failed.saturating_sub(1),
            GroupVerdict::Skip => self.skipped = self.skipped.saturating_sub(1),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutedGroupRecord {
    pub group_id: String,
    pub verdict: GroupVerdict,
    pub completed_at: String,
    #[serde(default)]
    pub state_capture_at_report: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecutedGroupChange {
    Noop,
    Inserted,
    Updated(GroupVerdict),
}

/// Run status tracked in run-status.json.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunStatus {
    pub run_id: String,
    pub suite_id: String,
    pub profile: String,
    pub started_at: String,
    pub overall_verdict: Verdict,
    #[serde(default)]
    pub completed_at: Option<String>,
    #[serde(default)]
    pub counts: RunCounts,
    #[serde(default)]
    pub executed_groups: Vec<ExecutedGroupRecord>,
    #[serde(default)]
    pub skipped_groups: Vec<String>,
    #[serde(default)]
    pub last_completed_group: Option<String>,
    #[serde(default)]
    pub last_state_capture: Option<String>,
    #[serde(default)]
    pub last_updated_utc: Option<String>,
    #[serde(default)]
    pub next_planned_group: Option<String>,
    #[serde(default)]
    pub notes: Vec<String>,
}

impl RunStatus {
    /// Load run status from a JSON file.
    ///
    /// # Errors
    /// Returns `CliError` if the file is missing or contains invalid JSON.
    pub fn load(path: &Path) -> Result<Self, CliError> {
        io::read_json_typed(path)
            .map_err(|error| -> CliError { CliErrorKind::json_parse(error.to_string()).into() })
    }

    /// Save run status to a JSON file.
    ///
    /// # Errors
    /// Returns `CliError` on IO or serialization failure.
    pub fn save(&self, path: &Path) -> Result<(), CliError> {
        io::write_json_pretty(path, self)
    }

    #[must_use]
    pub fn executed_group_ids(&self) -> Vec<&str> {
        self.executed_groups
            .iter()
            .map(|group| group.group_id.as_str())
            .collect()
    }

    #[must_use]
    pub fn group_verdict(&self, group_id: &str) -> Option<GroupVerdict> {
        self.executed_groups
            .iter()
            .find(|group| group.group_id == group_id)
            .map(|group| group.verdict)
    }

    pub fn record_group_result(
        &mut self,
        group_id: &str,
        verdict: GroupVerdict,
        completed_at: &str,
        state_capture_at_report: Option<&str>,
    ) -> ExecutedGroupChange {
        if let Some(group) = self
            .executed_groups
            .iter_mut()
            .find(|group| group.group_id == group_id)
        {
            if group.verdict == verdict {
                return ExecutedGroupChange::Noop;
            }
            let previous = group.verdict;
            self.counts.decrement(previous);
            group.verdict = verdict;
            group.completed_at = completed_at.to_string();
            group.state_capture_at_report = state_capture_at_report.map(str::to_string);
            self.counts.increment(verdict);
            return ExecutedGroupChange::Updated(previous);
        }

        self.executed_groups.push(ExecutedGroupRecord {
            group_id: group_id.to_string(),
            verdict,
            completed_at: completed_at.to_string(),
            state_capture_at_report: state_capture_at_report.map(str::to_string),
        });
        self.counts.increment(verdict);
        ExecutedGroupChange::Inserted
    }

    #[must_use]
    pub fn last_group_capture_value(&self) -> Option<&str> {
        self.executed_groups
            .last()
            .and_then(|group| group.state_capture_at_report.as_deref())
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn test_load_run_status() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run-status.json");
        let json = serde_json::json!({
            "run_id": "t",
            "suite_id": "s",
            "profile": "single-zone",
            "started_at": "now",
            "completed_at": null,
            "executed_groups": [],
            "skipped_groups": [],
            "overall_verdict": "pending",
            "last_state_capture": null,
            "notes": []
        });
        fs::write(&path, serde_json::to_string_pretty(&json).unwrap()).unwrap();

        let status = RunStatus::load(&path).unwrap();
        assert_eq!(status.last_state_capture, None);
        assert_eq!(status.counts, RunCounts::default());
        assert_eq!(status.last_completed_group, None);
        assert_eq!(status.next_planned_group, None);
    }

    #[test]
    fn test_load_run_status_accepts_structured_group_entries() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run-status.json");
        let json = serde_json::json!({
            "run_id": "t",
            "suite_id": "s",
            "profile": "single-zone",
            "started_at": "now",
            "completed_at": null,
            "counts": {"passed": 1, "failed": 0, "skipped": 0},
            "executed_groups": [
                {
                    "group_id": "g02",
                    "verdict": "pass",
                    "completed_at": "2026-03-14T07:57:19Z"
                }
            ],
            "skipped_groups": [],
            "last_completed_group": "g02",
            "overall_verdict": "pending",
            "last_state_capture": "state/after-g02.json",
            "last_updated_utc": "2026-03-14T07:57:19Z",
            "next_planned_group": "g03",
            "notes": []
        });
        fs::write(&path, serde_json::to_string_pretty(&json).unwrap()).unwrap();

        let status = RunStatus::load(&path).unwrap();
        assert_eq!(
            status.counts,
            RunCounts {
                passed: 1,
                failed: 0,
                skipped: 0,
            }
        );
        assert_eq!(status.executed_group_ids(), vec!["g02"]);
        assert_eq!(status.last_completed_group.as_deref(), Some("g02"));
        assert_eq!(status.next_planned_group.as_deref(), Some("g03"));
    }
}
