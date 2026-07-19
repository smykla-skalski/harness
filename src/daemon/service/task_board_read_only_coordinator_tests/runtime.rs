use std::collections::{BTreeMap, VecDeque};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use async_trait::async_trait;
use tokio::sync::Semaphore;

use crate::daemon::protocol::{CodexRunRequest, CodexRunSnapshot, CodexRunStatus};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardEvaluationResult, TaskBoardImplementationResult, TaskBoardLifecycleOutcome,
    TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict, TaskBoardReviewResult,
    TaskBoardReviewerOutcome, TaskBoardWorkflowExecutionRecord,
};

use super::super::task_board_read_only_runtime::{
    TaskBoardPublishVerification, TaskBoardReadOnlyRuntime,
};
use super::fixture::{FROZEN_HEAD, NOW};

pub(super) struct PlannedReport {
    action_key: String,
    attempt: u32,
    artifact: TaskBoardAttemptResultArtifact,
    status: CodexRunStatus,
}

impl PlannedReport {
    pub(super) fn passing_review() -> Self {
        Self::passing_review_for("reviewer-amber")
    }

    pub(super) fn passing_review_for(profile_id: &str) -> Self {
        Self {
            action_key: format!("review:{profile_id}"),
            attempt: 1,
            artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
                profile_id: profile_id.into(),
                result: TaskBoardReviewResult {
                    verdict: TaskBoardPhaseVerdict::Pass,
                    head_revision: FROZEN_HEAD.into(),
                    summary: "exact-head review passed".into(),
                    findings: Vec::new(),
                },
            }),
            status: CodexRunStatus::Completed,
        }
    }

    pub(super) fn running_review() -> Self {
        let mut report = Self::passing_review();
        report.status = CodexRunStatus::Running;
        report
    }

    pub(super) fn passing_evaluation() -> Self {
        Self {
            action_key: "evaluate".into(),
            attempt: 1,
            artifact: TaskBoardAttemptResultArtifact::Evaluation(TaskBoardEvaluationResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                summary: "durable review evidence passed evaluation".into(),
                evidence: vec!["review was bound to the frozen head".into()],
                head_revision: None,
                revision_cycle: None,
            }),
            status: CodexRunStatus::Completed,
        }
    }
}

enum HeadBehavior {
    Exact(String),
    Error(String),
}

pub(super) struct FakeReadOnlyRuntime {
    reports: Mutex<VecDeque<PlannedReport>>,
    runs: Mutex<BTreeMap<String, CodexRunSnapshot>>,
    head: Mutex<HeadBehavior>,
    starts: Mutex<Vec<String>>,
    requests: Mutex<Vec<CodexRunRequest>>,
    load_error: Mutex<Option<String>>,
    block_report: AtomicBool,
    report_entered: Semaphore,
    report_release: Semaphore,
    fail_start_after_persist: AtomicBool,
    publishes: AtomicUsize,
    block_publish: AtomicBool,
    publish_entered: Semaphore,
    publish_release: Semaphore,
    approved: AtomicBool,
    publish_error: Mutex<Option<String>>,
    approve_on_publish_error: AtomicBool,
    verification_error: Mutex<Option<String>>,
    verifications: AtomicUsize,
}

impl FakeReadOnlyRuntime {
    pub(super) fn new(reports: impl IntoIterator<Item = PlannedReport>) -> Self {
        Self {
            reports: Mutex::new(reports.into_iter().collect()),
            runs: Mutex::new(BTreeMap::new()),
            head: Mutex::new(HeadBehavior::Exact(FROZEN_HEAD.into())),
            starts: Mutex::new(Vec::new()),
            requests: Mutex::new(Vec::new()),
            load_error: Mutex::new(None),
            block_report: AtomicBool::new(false),
            report_entered: Semaphore::new(0),
            report_release: Semaphore::new(0),
            fail_start_after_persist: AtomicBool::new(false),
            publishes: AtomicUsize::new(0),
            block_publish: AtomicBool::new(false),
            publish_entered: Semaphore::new(0),
            publish_release: Semaphore::new(0),
            approved: AtomicBool::new(false),
            publish_error: Mutex::new(None),
            approve_on_publish_error: AtomicBool::new(false),
            verification_error: Mutex::new(None),
            verifications: AtomicUsize::new(0),
        }
    }

    pub(super) fn set_head(&self, head: &str) {
        *self.head.lock().expect("head lock") = HeadBehavior::Exact(head.into());
    }

    pub(super) fn set_head_error(&self, detail: &str) {
        *self.head.lock().expect("head lock") = HeadBehavior::Error(detail.into());
    }

    pub(super) fn start_count(&self) -> usize {
        self.starts.lock().expect("starts lock").len()
    }

    pub(super) fn publish_count(&self) -> usize {
        self.publishes.load(Ordering::SeqCst)
    }

    pub(super) fn verification_count(&self) -> usize {
        self.verifications.load(Ordering::SeqCst)
    }

    pub(super) fn last_request(&self) -> CodexRunRequest {
        self.requests
            .lock()
            .expect("requests lock")
            .last()
            .expect("captured request")
            .clone()
    }

    pub(super) fn set_all_run_statuses(&self, status: CodexRunStatus) {
        for run in self.runs.lock().expect("runs lock").values_mut() {
            run.status = status;
        }
    }

    pub(super) fn set_load_error(&self, detail: &str) {
        *self.load_error.lock().expect("load error lock") = Some(detail.into());
    }

    pub(super) fn block_report(&self) {
        self.block_report.store(true, Ordering::SeqCst);
    }

    pub(super) async fn wait_for_report_start(&self) {
        self.report_entered
            .acquire()
            .await
            .expect("report entry semaphore")
            .forget();
    }

    pub(super) fn release_report(&self) {
        self.report_release.add_permits(1);
    }

    pub(super) fn fail_next_start_after_persist(&self) {
        self.fail_start_after_persist.store(true, Ordering::SeqCst);
    }

    pub(super) fn block_publish(&self) {
        self.block_publish.store(true, Ordering::SeqCst);
    }

    pub(super) async fn wait_for_publish(&self) {
        self.publish_entered
            .acquire()
            .await
            .expect("publish entry semaphore")
            .forget();
    }

    pub(super) fn release_publish(&self) {
        self.publish_release.add_permits(1);
    }

    pub(super) fn set_approved(&self, approved: bool) {
        self.approved.store(approved, Ordering::SeqCst);
    }

    pub(super) fn set_publish_error(&self, detail: &str, approval_applied: bool) {
        *self.publish_error.lock().expect("publish error lock") = Some(detail.into());
        self.approve_on_publish_error
            .store(approval_applied, Ordering::SeqCst);
    }

    pub(super) fn set_verification_error(&self, detail: &str) {
        *self
            .verification_error
            .lock()
            .expect("verification error lock") = Some(detail.into());
    }
}

#[async_trait]
impl TaskBoardReadOnlyRuntime for FakeReadOnlyRuntime {
    async fn load_codex_report_run(
        &self,
        run_id: &str,
    ) -> Result<Option<CodexRunSnapshot>, CliError> {
        if let Some(detail) = self.load_error.lock().expect("load error lock").take() {
            return Err(CliErrorKind::workflow_io(detail).into());
        }
        Ok(self.runs.lock().expect("runs lock").get(run_id).cloned())
    }

    async fn start_codex_report_run(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
        run_id: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        self.starts.lock().expect("starts lock").push(run_id.into());
        self.requests
            .lock()
            .expect("requests lock")
            .push(request.clone());
        if self.block_report.load(Ordering::SeqCst) {
            self.report_entered.add_permits(1);
            self.report_release
                .acquire()
                .await
                .map_err(|error| {
                    CliError::from(CliErrorKind::invalid_transition(format!(
                        "report release semaphore closed: {error}"
                    )))
                })?
                .forget();
        }
        let plan = self
            .reports
            .lock()
            .expect("reports lock")
            .pop_front()
            .ok_or_else(|| CliError::from(CliErrorKind::invalid_transition("no planned report")))?;
        let execution_id = request
            .workflow_execution_id
            .as_deref()
            .ok_or_else(|| CliError::from(CliErrorKind::invalid_transition("no execution id")))?;
        let status = plan.status;
        let result = TaskBoardLocalAttemptResult {
            schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
            execution_id: execution_id.into(),
            action_key: plan.action_key,
            attempt: plan.attempt,
            idempotency_key: run_id.into(),
            exact_head_revision: FROZEN_HEAD.into(),
            artifact: plan.artifact,
        };
        let run = planned_run(session_id, request, run_id, &result, status)?;
        self.runs
            .lock()
            .expect("runs lock")
            .insert(run_id.into(), run.clone());
        if self.fail_start_after_persist.swap(false, Ordering::SeqCst) {
            return Err(CliErrorKind::workflow_io(
                "report start response was lost after durable persistence",
            )
            .into());
        }
        Ok(run)
    }

    async fn resolve_exact_head(
        &self,
        _execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<String, CliError> {
        match &*self.head.lock().expect("head lock") {
            HeadBehavior::Exact(head) => Ok(head.clone()),
            HeadBehavior::Error(detail) => Err(CliErrorKind::workflow_io(detail.clone()).into()),
        }
    }

    async fn implementation_result_descends_from_base(
        &self,
        _execution: &TaskBoardWorkflowExecutionRecord,
        _result: &TaskBoardImplementationResult,
    ) -> Result<bool, CliError> {
        Ok(true)
    }

    async fn publish_pr_review(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardLifecycleOutcome, CliError> {
        self.publishes.fetch_add(1, Ordering::SeqCst);
        if self.block_publish.load(Ordering::SeqCst) {
            self.publish_entered.add_permits(1);
            self.publish_release
                .acquire()
                .await
                .map_err(|error| {
                    CliError::from(CliErrorKind::invalid_transition(format!(
                        "publish release semaphore closed: {error}"
                    )))
                })?
                .forget();
        }
        if let Some(detail) = self
            .publish_error
            .lock()
            .expect("publish error lock")
            .take()
        {
            if self.approve_on_publish_error.load(Ordering::SeqCst) {
                self.approved.store(true, Ordering::SeqCst);
            }
            return Err(CliErrorKind::workflow_io(detail).into());
        }
        self.approved.store(true, Ordering::SeqCst);
        Ok(TaskBoardLifecycleOutcome {
            mutated: true,
            terminal: false,
            provider_revision: execution.snapshot.provider_revision.clone(),
            external_url: Some("https://github.com/example/compass/pull/17".into()),
        })
    }

    async fn verify_pr_review_approval(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardPublishVerification, CliError> {
        self.verifications.fetch_add(1, Ordering::SeqCst);
        if let Some(detail) = self
            .verification_error
            .lock()
            .expect("verification error lock")
            .take()
        {
            return Err(CliErrorKind::workflow_io(detail).into());
        }
        let head = match &*self.head.lock().expect("head lock") {
            HeadBehavior::Exact(head) => head.clone(),
            HeadBehavior::Error(detail) => {
                return Err(CliErrorKind::workflow_io(detail.clone()).into());
            }
        };
        if execution.transition.exact_head_revision.as_deref() != Some(head.as_str()) {
            return Err(CliErrorKind::invalid_transition(
                "PrReview head changed during approval verification",
            )
            .into());
        }
        if self.approved.load(Ordering::SeqCst) {
            Ok(TaskBoardPublishVerification::Applied(
                TaskBoardLifecycleOutcome {
                    mutated: false,
                    terminal: false,
                    provider_revision: execution.snapshot.provider_revision.clone(),
                    external_url: Some("https://github.com/example/compass/pull/17".into()),
                },
            ))
        } else {
            Ok(TaskBoardPublishVerification::Absent)
        }
    }
}

fn planned_run(
    session_id: &str,
    request: &CodexRunRequest,
    run_id: &str,
    result: &TaskBoardLocalAttemptResult,
    status: CodexRunStatus,
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
        status,
        prompt: request.prompt.clone(),
        latest_summary: Some("report completed".into()),
        final_message: Some(serde_json::to_string(result).map_err(|error| {
            CliError::from(CliErrorKind::invalid_transition(format!(
                "serialize fake result: {error}"
            )))
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
