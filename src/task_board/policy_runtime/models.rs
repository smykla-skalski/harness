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
    pub trigger: PolicyRunTrigger,
    pub status: PolicyRunStatus,
    #[serde(default)]
    pub cursor: PolicyRunCursor,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_on: Option<PolicyWaitCondition>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<PolicyWorkflowStepRecord>,
    pub created_at: String,
    pub updated_at: String,
}

impl PolicyWorkflowRun {
    #[must_use]
    pub fn new(workflow_id: &str, subject: PolicyRunSubject, trigger: PolicyRunTrigger) -> Self {
        let now = utc_now();
        Self {
            run_id: format!("{workflow_id}-{}", Uuid::new_v4().simple()),
            workflow_id: workflow_id.to_owned(),
            subject,
            trigger,
            status: PolicyRunStatus::Running,
            cursor: PolicyRunCursor::default(),
            waiting_on: None,
            steps: Vec::new(),
            created_at: now.clone(),
            updated_at: now,
        }
    }

    #[must_use]
    pub fn waiting_for_event(
        workflow_id: &str,
        subject: PolicyRunSubject,
        wait: PolicyWaitCondition,
    ) -> Self {
        let mut run = Self::new(workflow_id, subject, PolicyRunTrigger::Background);
        run.mark_waiting(wait, 0);
        run
    }

    #[must_use]
    pub fn active_dedupe_key(&self) -> String {
        format!("{}::{}", self.workflow_id, self.subject.key)
    }

    pub fn record_action(&mut self, action_key: String, next_step_index: usize) {
        self.steps.push(PolicyWorkflowStepRecord {
            action_key,
            recorded_at: utc_now(),
        });
        self.cursor.next_step_index = next_step_index;
        self.updated_at = utc_now();
    }

    pub fn mark_waiting(&mut self, wait: PolicyWaitCondition, next_step_index: usize) {
        self.status = PolicyRunStatus::Waiting;
        self.waiting_on = Some(wait);
        self.cursor.next_step_index = next_step_index;
        self.updated_at = utc_now();
    }

    pub fn mark_completed(&mut self) {
        self.status = PolicyRunStatus::Completed;
        self.waiting_on = None;
        self.updated_at = utc_now();
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
        let (repository, pull_request) = identifier
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
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyRunCursor {
    #[serde(default)]
    pub next_step_index: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyWorkflowStepRecord {
    pub action_key: String,
    pub recorded_at: String,
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
