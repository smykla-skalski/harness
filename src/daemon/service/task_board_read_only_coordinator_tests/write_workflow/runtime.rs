use std::collections::{BTreeMap, VecDeque};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use async_trait::async_trait;

use crate::daemon::protocol::{CodexRunRequest, CodexRunSnapshot, CodexRunStatus};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardEvaluationResult, TaskBoardImplementationResult, TaskBoardLifecycleOutcome,
    TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict, TaskBoardReviewResult,
    TaskBoardReviewerOutcome, TaskBoardWorkflowExecutionRecord,
};

use super::super::super::task_board_read_only_runtime::{
    TaskBoardPublishVerification, TaskBoardReadOnlyRuntime,
};
use super::{BASE_HEAD, NOW};

pub(super) struct PlannedRun {
    action_key: String,
    attempt: u32,
    exact_head: String,
    artifact: TaskBoardAttemptResultArtifact,
}

impl PlannedRun {
    pub(super) fn implementation(cycle: u32, attempt: u32, base: &str, head: &str) -> Self {
        Self {
            action_key: format!("implementation:{cycle}"),
            attempt,
            exact_head: head.into(),
            artifact: TaskBoardAttemptResultArtifact::Implementation(
                TaskBoardImplementationResult {
                    revision_cycle: cycle,
                    base_head_revision: base.into(),
                    head_revision: head.into(),
                    summary: format!("implemented revision cycle {cycle}"),
                    evidence: vec!["focused validation passed".into()],
                },
            ),
        }
    }

    pub(super) fn review(attempt: u32, head: &str, verdict: TaskBoardPhaseVerdict) -> Self {
        Self {
            action_key: "review:reviewer-amber".into(),
            attempt,
            exact_head: head.into(),
            artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
                profile_id: "reviewer-amber".into(),
                result: TaskBoardReviewResult {
                    verdict,
                    head_revision: head.into(),
                    summary: "reviewed exact head".into(),
                    findings: Vec::new(),
                },
            }),
        }
    }

    pub(super) fn evaluation(cycle: u32, head: &str) -> Self {
        Self {
            action_key: format!("evaluate:{cycle}"),
            attempt: 1,
            exact_head: head.into(),
            artifact: TaskBoardAttemptResultArtifact::Evaluation(TaskBoardEvaluationResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                summary: "evaluation passed".into(),
                evidence: vec!["review evidence is consistent".into()],
                head_revision: Some(head.into()),
                revision_cycle: Some(cycle),
            }),
        }
    }
}

pub(super) struct FakeWriteRuntime {
    plans: Mutex<VecDeque<PlannedRun>>,
    runs: Mutex<BTreeMap<String, CodexRunSnapshot>>,
    head: Mutex<String>,
    starts: AtomicUsize,
    publishes: AtomicUsize,
    published: AtomicBool,
}

impl FakeWriteRuntime {
    pub(super) fn new(plans: impl IntoIterator<Item = PlannedRun>) -> Self {
        Self {
            plans: Mutex::new(plans.into_iter().collect()),
            runs: Mutex::new(BTreeMap::new()),
            head: Mutex::new(BASE_HEAD.into()),
            starts: AtomicUsize::new(0),
            publishes: AtomicUsize::new(0),
            published: AtomicBool::new(false),
        }
    }

    pub(super) fn start_count(&self) -> usize {
        self.starts.load(Ordering::SeqCst)
    }

    pub(super) fn publish_count(&self) -> usize {
        self.publishes.load(Ordering::SeqCst)
    }

    fn load_run(&self, run_id: &str) -> Option<CodexRunSnapshot> {
        self.runs.lock().expect("runs lock").get(run_id).cloned()
    }

    fn start_run(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
        run_id: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        self.starts.fetch_add(1, Ordering::SeqCst);
        let plan = self
            .plans
            .lock()
            .expect("plans lock")
            .pop_front()
            .ok_or_else(|| CliErrorKind::invalid_transition("no planned write run"))?;
        let result = TaskBoardLocalAttemptResult {
            schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
            execution_id: request
                .workflow_execution_id
                .clone()
                .ok_or_else(|| CliErrorKind::invalid_transition("no execution id"))?,
            action_key: plan.action_key,
            attempt: plan.attempt,
            idempotency_key: run_id.into(),
            exact_head_revision: plan.exact_head.clone(),
            artifact: plan.artifact,
        };
        *self.head.lock().expect("head lock") = plan.exact_head;
        let run = completed_run(session_id, request, run_id, result)?;
        self.runs
            .lock()
            .expect("runs lock")
            .insert(run_id.into(), run.clone());
        Ok(run)
    }
}

fn completed_run(
    session_id: &str,
    request: &CodexRunRequest,
    run_id: &str,
    result: TaskBoardLocalAttemptResult,
) -> Result<CodexRunSnapshot, CliError> {
    Ok(CodexRunSnapshot {
        run_id: run_id.into(),
        session_id: session_id.into(),
        task_id: request.task_id.clone(),
        board_item_id: request.board_item_id.clone(),
        workflow_execution_id: request.workflow_execution_id.clone(),
        session_agent_id: Some(format!("agent-{run_id}")),
        display_name: request.name.clone(),
        project_dir: "/tmp/read-only-worktree".into(),
        thread_id: Some(format!("thread-{run_id}")),
        turn_id: Some(format!("turn-{run_id}")),
        mode: request.mode,
        status: CodexRunStatus::Completed,
        prompt: request.prompt.clone(),
        latest_summary: Some("write run completed".into()),
        final_message: Some(serde_json::to_string(&result).map_err(|error| {
            CliErrorKind::invalid_transition(format!("serialize result: {error}"))
        })?),
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: NOW.into(),
        updated_at: NOW.into(),
        model: request.model.clone(),
        effort: request.effort.clone(),
    })
}

#[async_trait]
impl TaskBoardReadOnlyRuntime for FakeWriteRuntime {
    async fn load_codex_report_run(
        &self,
        run_id: &str,
    ) -> Result<Option<CodexRunSnapshot>, CliError> {
        Ok(self.load_run(run_id))
    }

    async fn start_codex_report_run(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
        run_id: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        self.start_run(session_id, request, run_id)
    }

    async fn load_codex_workspace_run(
        &self,
        run_id: &str,
    ) -> Result<Option<CodexRunSnapshot>, CliError> {
        Ok(self.load_run(run_id))
    }

    async fn start_codex_workspace_run(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
        run_id: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        self.start_run(session_id, request, run_id)
    }

    async fn resolve_exact_head(
        &self,
        _execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<String, CliError> {
        Ok(self.head.lock().expect("head lock").clone())
    }

    async fn publish_pr_review(
        &self,
        _execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardLifecycleOutcome, CliError> {
        Err(CliErrorKind::invalid_transition("not a read-only publication").into())
    }

    async fn verify_pr_review_approval(
        &self,
        _execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardPublishVerification, CliError> {
        Err(CliErrorKind::invalid_transition("not a read-only publication").into())
    }

    async fn publish_write_workflow(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardLifecycleOutcome, CliError> {
        self.publishes.fetch_add(1, Ordering::SeqCst);
        self.published.store(true, Ordering::SeqCst);
        Ok(publication(execution, true))
    }

    async fn verify_write_workflow_publication(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
        _known_external_url: Option<&str>,
    ) -> Result<TaskBoardPublishVerification, CliError> {
        if self.published.load(Ordering::SeqCst) {
            Ok(TaskBoardPublishVerification::Applied(publication(
                execution, false,
            )))
        } else {
            Ok(TaskBoardPublishVerification::Absent)
        }
    }
}

fn publication(
    execution: &TaskBoardWorkflowExecutionRecord,
    mutated: bool,
) -> TaskBoardLifecycleOutcome {
    TaskBoardLifecycleOutcome {
        mutated,
        terminal: false,
        provider_revision: execution.snapshot.provider_revision.clone(),
        external_url: Some("https://github.com/example/compass/pull/42".into()),
    }
}
