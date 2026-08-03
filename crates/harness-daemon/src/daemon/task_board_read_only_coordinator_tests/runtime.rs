use std::collections::{BTreeMap, VecDeque};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use async_trait::async_trait;
use tokio::sync::Semaphore;

use crate::daemon::db::{AgentTurnRunSnapshot, AgentTurnRunStatus, AsyncDaemonDb};
use crate::daemon::protocol::{CodexRunRequest, CodexRunSnapshot, CodexRunStatus};
use crate::daemon::test_liveness::LIVENESS;
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardImplementationResult,
    TaskBoardLifecycleOutcome, TaskBoardLocalAttemptResult, TaskBoardWorkflowExecutionRecord,
};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::super::task_board_read_only_runtime::{
    AgentTurnReportStart, TaskBoardPublishVerification, TaskBoardReadOnlyRuntime,
};
use super::fixture::{FROZEN_HEAD, NOW};

#[path = "runtime/planned_report.rs"]
mod planned_report;

pub(super) use planned_report::PlannedReport;
use crate::daemon::db::prelude::*;

enum HeadBehavior {
    Exact(String),
    Error(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(in crate::daemon) struct CapturedAgentTurnStart {
    pub(in crate::daemon) runtime: String,
    pub(in crate::daemon) prompt: String,
    pub(in crate::daemon) requested_model: Option<String>,
    pub(in crate::daemon) pull_request_body: Option<String>,
    pub(in crate::daemon) head_revision: Option<String>,
}

pub(in crate::daemon) struct FakeReadOnlyRuntime {
    durable_db: Option<AsyncDaemonDb>,
    reports: Mutex<VecDeque<PlannedReport>>,
    runs: Mutex<BTreeMap<String, CodexRunSnapshot>>,
    head: Mutex<HeadBehavior>,
    immutable_content: Mutex<Result<String, String>>,
    immutable_content_loads: AtomicUsize,
    starts: Mutex<Vec<String>>,
    agent_turn_starts: Mutex<Vec<CapturedAgentTurnStart>>,
    requests: Mutex<Vec<CodexRunRequest>>,
    load_error: Mutex<Option<String>>,
    block_report: AtomicBool,
    report_entered: Semaphore,
    report_release: Semaphore,
    fail_start_after_persist: AtomicBool,
    evict_agent_turn_on_load: AtomicBool,
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
    pub(in crate::daemon) fn new(reports: impl IntoIterator<Item = PlannedReport>) -> Self {
        Self {
            durable_db: None,
            reports: Mutex::new(reports.into_iter().collect()),
            runs: Mutex::new(BTreeMap::new()),
            head: Mutex::new(HeadBehavior::Exact(FROZEN_HEAD.into())),
            immutable_content: Mutex::new(Ok(
                r#"{"pull_request":{"title":"Frozen test pull request"},"patches":[]}"#.into(),
            )),
            immutable_content_loads: AtomicUsize::new(0),
            starts: Mutex::new(Vec::new()),
            agent_turn_starts: Mutex::new(Vec::new()),
            requests: Mutex::new(Vec::new()),
            load_error: Mutex::new(None),
            block_report: AtomicBool::new(false),
            report_entered: Semaphore::new(0),
            report_release: Semaphore::new(0),
            fail_start_after_persist: AtomicBool::new(false),
            evict_agent_turn_on_load: AtomicBool::new(false),
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

    pub(in crate::daemon) fn with_durable_db(mut self, db: AsyncDaemonDb) -> Self {
        self.durable_db = Some(db);
        self
    }

    pub(in crate::daemon) fn set_immutable_content(&self, content: &str) {
        *self
            .immutable_content
            .lock()
            .expect("immutable content lock") = Ok(content.into());
    }

    pub(super) fn fail_immutable_content(&self, detail: &str) {
        *self
            .immutable_content
            .lock()
            .expect("immutable content lock") = Err(detail.into());
    }

    pub(super) fn immutable_content_load_count(&self) -> usize {
        self.immutable_content_loads.load(Ordering::SeqCst)
    }

    pub(in crate::daemon) fn set_head(&self, head: &str) {
        *self.head.lock().expect("head lock") = HeadBehavior::Exact(head.into());
    }

    pub(super) fn set_head_error(&self, detail: &str) {
        *self.head.lock().expect("head lock") = HeadBehavior::Error(detail.into());
    }

    pub(in crate::daemon) fn start_count(&self) -> usize {
        self.starts.lock().expect("starts lock").len()
    }

    pub(in crate::daemon) fn publish_count(&self) -> usize {
        self.publishes.load(Ordering::SeqCst)
    }

    pub(in crate::daemon) fn last_agent_turn_start(&self) -> CapturedAgentTurnStart {
        self.agent_turn_starts
            .lock()
            .expect("agent-turn starts lock")
            .last()
            .expect("captured agent-turn start")
            .clone()
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

    /// Force every started run to finish `Completed` with a raw final message
    /// that is not valid workflow evidence, so the coordinator has to reconcile
    /// a malformed completion.
    pub(super) fn complete_all_runs_with_message(&self, message: &str) {
        for run in self.runs.lock().expect("runs lock").values_mut() {
            run.status = CodexRunStatus::Completed;
            run.final_message = Some(message.into());
        }
    }

    pub(super) fn set_load_error(&self, detail: &str) {
        *self.load_error.lock().expect("load error lock") = Some(detail.into());
    }

    pub(super) fn block_report(&self) {
        self.block_report.store(true, Ordering::SeqCst);
    }

    pub(super) async fn wait_for_report_start(&self) {
        tokio::time::timeout(LIVENESS, self.report_entered.acquire())
            .await
            .expect("timed out waiting for report entry")
            .expect("report entry semaphore")
            .forget();
    }

    pub(super) fn release_report(&self) {
        self.report_release.add_permits(1);
    }

    pub(super) fn fail_next_start_after_persist(&self) {
        self.fail_start_after_persist.store(true, Ordering::SeqCst);
    }

    pub(super) fn evict_agent_turn_on_next_load(&self) {
        self.evict_agent_turn_on_load.store(true, Ordering::SeqCst);
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
        if let Some(db) = &self.durable_db {
            return db.codex_run(run_id).await;
        }
        Ok(self.runs.lock().expect("runs lock").get(run_id).cloned())
    }

    async fn start_report_run(
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
        let project_dir = if let Some(db) = &self.durable_db {
            db.resolve_session(session_id)
                .await?
                .ok_or_else(|| {
                    CliError::from(CliErrorKind::session_not_found(session_id.to_string()))
                })?
                .state
                .worktree_path
                .to_string_lossy()
                .into_owned()
        } else {
            "/tmp/read-only-worktree".into()
        };
        let run = planned_run(session_id, request, run_id, &project_dir, &result, status)?;
        if let Some(db) = &self.durable_db {
            db.save_codex_run(&run).await?;
        }
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

    async fn start_agent_turn_report_run(
        &self,
        start: AgentTurnReportStart<'_>,
    ) -> Result<(), CliError> {
        self.agent_turn_starts
            .lock()
            .expect("agent-turn starts lock")
            .push(CapturedAgentTurnStart {
                runtime: start.runtime.into(),
                prompt: start.prompt.clone(),
                requested_model: start.requested_model.clone(),
                pull_request_body: start
                    .pull_request
                    .as_ref()
                    .map(|pull_request| pull_request.content.body.clone()),
                head_revision: start
                    .pull_request
                    .as_ref()
                    .map(|pull_request| pull_request.pull_request.head_revision.clone()),
            });
        self.starts
            .lock()
            .expect("starts lock")
            .push(start.run_id.into());
        let db = self.durable_db.as_ref().ok_or_else(|| {
            CliError::from(CliErrorKind::invalid_transition(
                "fake agent-turn runtime needs a durable database",
            ))
        })?;
        db.record_agent_turn_run_started(&AgentTurnRunSnapshot {
            run_id: start.run_id.into(),
            session_id: Some(start.session_id.into()),
            task_id: None,
            board_item_id: Some(start.board_item_id.into()),
            workflow_execution_id: Some(start.workflow_execution_id.into()),
            project_dir: start.project_dir.clone(),
            requested_runtime: start.runtime.into(),
            actual_runtime: Some(start.runtime.into()),
            runtime_turn_id: Some(format!("turn-{}", start.run_id)),
            requested_model: start.requested_model.clone(),
            actual_model: None,
            status: AgentTurnRunStatus::Running,
            source_revision: start
                .pull_request
                .as_ref()
                .map(|pull_request| pull_request.pull_request.head_revision.clone()),
            report: None,
            stop_reason: None,
            error: None,
            created_at: NOW.into(),
            updated_at: NOW.into(),
        })
        .await?;
        if self.fail_start_after_persist.swap(false, Ordering::SeqCst) {
            return Err(CliErrorKind::workflow_io(
                "agent-turn start response was lost after durable persistence",
            )
            .into());
        }
        Ok(())
    }

    async fn load_agent_turn_report_run(
        &self,
        run_id: &str,
    ) -> Result<Option<AgentTurnRunSnapshot>, CliError> {
        let db = self.durable_db.as_ref().ok_or_else(|| {
            CliError::from(CliErrorKind::invalid_transition(
                "fake agent-turn runtime needs a durable database",
            ))
        })?;
        let Some(mut run) = db.agent_turn_run(run_id).await? else {
            return Ok(None);
        };
        if run.status.is_active() && self.evict_agent_turn_on_load.swap(false, Ordering::SeqCst) {
            run.status = AgentTurnRunStatus::Failed;
            run.error = Some("provider turn is no longer attached to this daemon".into());
            db.save_agent_turn_run(&run).await?;
            return db.agent_turn_run(run_id).await;
        }
        Ok(Some(run))
    }

    async fn immutable_pull_request_content(
        &self,
        _repository: &str,
        _number: u64,
        _expected_head: &str,
    ) -> Result<String, CliError> {
        self.immutable_content_loads.fetch_add(1, Ordering::SeqCst);
        self.immutable_content
            .lock()
            .expect("immutable content lock")
            .clone()
            .map_err(|detail| CliErrorKind::workflow_io(detail).into())
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
    project_dir: &str,
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
        project_dir: project_dir.into(),
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
