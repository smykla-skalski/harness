use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::task_board::PolicySubject;
use crate::task_board::policy_graph::PolicyWaitCondition;
use crate::workspace::utc_now;

pub const POLICY_WORKFLOW_RUNS_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyWorkflowRunsDocument {
    pub schema_version: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub runs: Vec<PolicyWorkflowRun>,
}

impl Default for PolicyWorkflowRunsDocument {
    fn default() -> Self {
        Self {
            schema_version: POLICY_WORKFLOW_RUNS_SCHEMA_VERSION,
            runs: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyWorkflowRun {
    pub run_id: String,
    pub workflow_id: String,
    pub subject: PolicyRunSubject,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject_fingerprint: Option<String>,
    pub trigger: PolicyRunTrigger,
    pub status: PolicyRunStatus,
    #[serde(default)]
    pub cursor: PolicyRunCursor,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub planned_steps: Vec<PolicyRunStep>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_on: Option<PolicyWaitCondition>,
    /// Timestamp the run entered its current wait. Timer deadlines are
    /// computed from this instant, not `updated_at`, so a manual nudge
    /// (which bumps `updated_at`) cannot push a pending timer forward.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_since: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<PolicyWorkflowStepRecord>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

impl PolicyWorkflowRun {
    #[must_use]
    pub fn new(
        workflow_id: &str,
        subject: PolicyRunSubject,
        subject_fingerprint: Option<String>,
        trigger: PolicyRunTrigger,
        planned_steps: Vec<PolicyRunStep>,
    ) -> Self {
        let now = utc_now();
        let run_id_prefix = workflow_id.replace('_', "-");
        Self {
            run_id: format!("{run_id_prefix}-{}", Uuid::new_v4().simple()),
            workflow_id: workflow_id.to_owned(),
            subject,
            subject_fingerprint,
            trigger,
            status: PolicyRunStatus::Running,
            cursor: PolicyRunCursor::default(),
            planned_steps,
            waiting_on: None,
            waiting_since: None,
            steps: Vec::new(),
            created_at: now.clone(),
            updated_at: now,
            completed_at: None,
            error_message: None,
        }
    }

    #[must_use]
    pub fn waiting_for_event(
        workflow_id: &str,
        subject: PolicyRunSubject,
        wait: PolicyWaitCondition,
    ) -> Self {
        let mut run = Self::new(
            workflow_id,
            subject,
            None,
            PolicyRunTrigger::Background,
            Vec::new(),
        );
        run.mark_waiting(wait, 0);
        run
    }

    #[must_use]
    pub fn active_dedupe_key(&self) -> String {
        match self.subject_fingerprint.as_deref() {
            Some(fingerprint) => {
                format!(
                    "{}::{}::{}",
                    self.workflow_id, self.subject.key, fingerprint
                )
            }
            None => format!("{}::{}", self.workflow_id, self.subject.key),
        }
    }

    pub fn record_action(&mut self, action_key: String, next_step_index: usize) {
        let now = utc_now();
        self.steps.push(PolicyWorkflowStepRecord {
            step_type: PolicyWorkflowStepType::Action,
            action_key: Some(action_key),
            waiting_on: None,
            recorded_at: now.clone(),
        });
        self.cursor.next_step_index = next_step_index;
        self.updated_at = now;
    }

    pub fn mark_waiting(&mut self, wait: PolicyWaitCondition, next_step_index: usize) {
        let now = utc_now();
        self.status = PolicyRunStatus::Waiting;
        self.waiting_on = Some(wait.clone());
        self.waiting_since = Some(now.clone());
        self.steps.push(PolicyWorkflowStepRecord {
            step_type: PolicyWorkflowStepType::Wait,
            action_key: None,
            waiting_on: Some(wait),
            recorded_at: now.clone(),
        });
        self.cursor.next_step_index = next_step_index;
        self.updated_at = now;
    }

    pub fn mark_running(&mut self, trigger: PolicyRunTrigger) {
        self.trigger = trigger;
        self.status = PolicyRunStatus::Running;
        self.waiting_on = None;
        self.waiting_since = None;
        self.error_message = None;
        self.updated_at = utc_now();
    }

    pub fn mark_completed(&mut self) {
        let now = utc_now();
        self.status = PolicyRunStatus::Completed;
        self.waiting_on = None;
        self.waiting_since = None;
        self.updated_at.clone_from(&now);
        self.completed_at = Some(now);
        self.error_message = None;
    }

    pub fn mark_failed(&mut self, message: impl Into<String>) {
        let now = utc_now();
        self.status = PolicyRunStatus::Failed;
        self.waiting_on = None;
        self.waiting_since = None;
        self.updated_at.clone_from(&now);
        self.completed_at = Some(now);
        self.error_message = Some(message.into());
    }

    pub fn mark_cancelled(&mut self, message: impl Into<String>) {
        let now = utc_now();
        self.status = PolicyRunStatus::Cancelled;
        self.waiting_on = None;
        self.waiting_since = None;
        self.updated_at.clone_from(&now);
        self.completed_at = Some(now);
        self.error_message = Some(message.into());
    }

    pub fn nudge_manually(&mut self) {
        self.trigger = PolicyRunTrigger::ManualNudge;
        self.updated_at = utc_now();
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyRunSubject {
    pub kind: String,
    pub key: String,
    #[serde(default)]
    pub policy_subject: PolicySubject,
}

impl PolicyRunSubject {
    #[must_use]
    pub fn review_pr(identifier: &str) -> Self {
        let (repository, pull_request) =
            identifier
                .split_once('#')
                .map_or((None, None), |(repository, pull_request)| {
                    (Some(repository.to_owned()), Some(pull_request.to_owned()))
                });
        Self {
            kind: "review_pr".to_owned(),
            key: identifier.to_owned(),
            policy_subject: PolicySubject {
                repository,
                pull_request,
                ..PolicySubject::default()
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyRunTrigger {
    Background,
    Manual,
    ManualNudge,
    Event,
    Timer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyRunStatus {
    Running,
    Waiting,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyRunCursor {
    #[serde(default)]
    pub next_step_index: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyWorkflowStepRecord {
    #[serde(default)]
    pub step_type: PolicyWorkflowStepType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_on: Option<PolicyWaitCondition>,
    pub recorded_at: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyWorkflowStepType {
    #[default]
    Action,
    Wait,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyActionDescriptor {
    pub provider: String,
    pub action_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum PolicyRunStep {
    Action(PolicyActionDescriptor),
    Wait(PolicyWaitCondition),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyRunRequest {
    pub workflow_id: String,
    pub subject: PolicyRunSubject,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject_fingerprint: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<PolicyRunStep>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyWorkflowEvent {
    pub event_key: String,
    pub subject_key: String,
    pub occurred_at: String,
}

impl PolicyWorkflowEvent {
    #[must_use]
    pub fn named(event_key: &str, subject_key: &str) -> Self {
        Self {
            event_key: event_key.to_owned(),
            subject_key: subject_key.to_owned(),
            occurred_at: utc_now(),
        }
    }
}

/// Aggregate status and trigger counts across a set of policy workflow runs.
/// Drives the observability surface so the Monitor app can render run totals
/// without re-deriving them from the raw run list on every refresh.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyRunMetrics {
    pub total: usize,
    pub running: usize,
    pub waiting: usize,
    pub completed: usize,
    pub failed: usize,
    pub cancelled: usize,
    /// Run counts keyed by the `snake_case` trigger name (`background`,
    /// `manual`, `manual_nudge`, `event`, `timer`). Sorted for stable output.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub by_trigger: BTreeMap<String, usize>,
}

/// Summarize a set of runs into status and trigger counts.
#[must_use]
pub fn compute_run_metrics(runs: &[PolicyWorkflowRun]) -> PolicyRunMetrics {
    let mut metrics = PolicyRunMetrics {
        total: runs.len(),
        ..PolicyRunMetrics::default()
    };
    for run in runs {
        match run.status {
            PolicyRunStatus::Running => metrics.running += 1,
            PolicyRunStatus::Waiting => metrics.waiting += 1,
            PolicyRunStatus::Completed => metrics.completed += 1,
            PolicyRunStatus::Failed => metrics.failed += 1,
            PolicyRunStatus::Cancelled => metrics.cancelled += 1,
        }
        *metrics
            .by_trigger
            .entry(trigger_metric_key(run.trigger).to_owned())
            .or_insert(0) += 1;
    }
    metrics
}

fn trigger_metric_key(trigger: PolicyRunTrigger) -> &'static str {
    match trigger {
        PolicyRunTrigger::Background => "background",
        PolicyRunTrigger::Manual => "manual",
        PolicyRunTrigger::ManualNudge => "manual_nudge",
        PolicyRunTrigger::Event => "event",
        PolicyRunTrigger::Timer => "timer",
    }
}
