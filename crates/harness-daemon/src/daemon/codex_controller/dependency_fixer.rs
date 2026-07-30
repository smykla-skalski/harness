use async_trait::async_trait;
use chrono::{DateTime, TimeDelta, Utc};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_task_board::{
    TASK_BOARD_DEPENDENCY_FIXER_EFFORT, TASK_BOARD_DEPENDENCY_FIXER_MODEL,
    TaskBoardDependencyCheckResumeRecord, TaskBoardDependencyFixAttemptOutcome,
    TaskBoardDependencyFixAuditSink, TaskBoardDependencyFixAuditTrail,
    TaskBoardDependencyFixAutomationStatus, TaskBoardDependencyFixBinding,
    TaskBoardDependencyFixDispatchOutcome, TaskBoardDependencyFixExplicitRetry,
    TaskBoardDependencyFixFailedAttempt, TaskBoardDependencyFixLauncher,
    TaskBoardDependencyFixRequest, TaskBoardDependencyFixResult, TaskBoardDependencyFixRun,
    TaskBoardDependencyRouteStore, TaskBoardDependencyTriageResult, TaskBoardStatus,
    TaskBoardWorkflowStatus, continue_task_board_dependency_fix_after_failed_checks,
    dispatch_explicit_task_board_dependency_fix_retry, render_task_board_dependency_fix_prompt,
    route_and_dispatch_task_board_dependency_fix, task_board_dependency_fix_timeout_audit,
    validate_task_board_dependency_fix_audit,
};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest, CodexRunStatus};
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};

use super::CodexControllerHandle;

#[derive(Clone)]
pub struct CodexDependencyFixLauncher {
    controller: CodexControllerHandle,
}

impl CodexDependencyFixLauncher {
    #[must_use]
    pub fn new(controller: CodexControllerHandle) -> Self {
        Self { controller }
    }
}

impl CodexControllerHandle {
    /// Route validated dependency triage and start the bound fixer when it requires source changes.
    ///
    /// # Errors
    ///
    /// Returns route admission, validation, persistence, or Codex startup errors.
    pub async fn route_dependency_triage_and_start_fixer(
        &self,
        result: &TaskBoardDependencyTriageResult,
        expected_repository: &str,
        expected_pull_request_number: u64,
        expected_head_revision: &str,
        store: &dyn TaskBoardDependencyRouteStore,
        binding: &TaskBoardDependencyFixBinding,
    ) -> Result<TaskBoardDependencyFixDispatchOutcome, CliError> {
        let launcher = CodexDependencyFixLauncher::new(self.clone());
        route_and_dispatch_task_board_dependency_fix(
            result,
            expected_repository,
            expected_pull_request_number,
            expected_head_revision,
            store,
            binding,
            &launcher,
        )
        .await
    }

    /// Persist a failed attempt's audit and start the next policy-authorized fixer.
    ///
    /// # Errors
    ///
    /// Returns policy, evidence, ticket persistence, or Codex startup errors.
    pub async fn continue_dependency_fix_after_failed_checks(
        &self,
        failed: TaskBoardDependencyFixFailedAttempt<'_>,
    ) -> Result<TaskBoardDependencyFixAttemptOutcome, CliError> {
        let audit_sink = self.dependency_fix_audit_sink()?;
        let launcher = CodexDependencyFixLauncher::new(self.clone());
        continue_task_board_dependency_fix_after_failed_checks(
            failed,
            audit_sink.as_ref(),
            &launcher,
        )
        .await
    }

    /// Persist and start one user-authorized retry with its existing audit history.
    ///
    /// # Errors
    ///
    /// Returns evidence, ticket persistence, or Codex startup errors.
    pub async fn retry_dependency_fix_explicitly(
        &self,
        previous_request: &TaskBoardDependencyFixRequest,
        previous_run: &TaskBoardDependencyFixRun,
        previous_result: Option<&TaskBoardDependencyFixResult>,
        checks: Option<&TaskBoardDependencyCheckResumeRecord>,
        stopped_audit: &TaskBoardDependencyFixAuditTrail,
    ) -> Result<TaskBoardDependencyFixAttemptOutcome, CliError> {
        let audit_sink = self.dependency_fix_audit_sink()?;
        let launcher = CodexDependencyFixLauncher::new(self.clone());
        let authorized_at = Utc::now().to_rfc3339();
        dispatch_explicit_task_board_dependency_fix_retry(
            TaskBoardDependencyFixExplicitRetry {
                previous_request,
                previous_run,
                previous_result,
                checks,
                stopped_audit,
                authorized_at: &authorized_at,
            },
            audit_sink.as_ref(),
            &launcher,
        )
        .await
    }

    fn dependency_fix_audit_sink(&self) -> Result<std::sync::Arc<AsyncDaemonDb>, CliError> {
        self.state.async_db.get().cloned().ok_or_else(|| {
            CliErrorKind::workflow_io(
                "dependency fixer ticket audit requires the async daemon database",
            )
            .into()
        })
    }
}

const DEPENDENCY_FIX_AUDIT_START: &str = "<!-- harness:dependency-fix-audit:start -->";
const DEPENDENCY_FIX_AUDIT_CLOSE: &str = "\n```\n<!-- harness:dependency-fix-audit:end -->";

#[async_trait]
impl TaskBoardDependencyFixAuditSink for AsyncDaemonDb {
    async fn record(&self, audit: &TaskBoardDependencyFixAuditTrail) -> Result<(), CliError> {
        validate_task_board_dependency_fix_audit(audit)?;
        let audit = audit.clone();
        let item_id = audit.board_item_id.clone();
        self.update_task_board_item(&item_id, move |item| {
            if item.workflow.execution_id.as_deref() != Some(audit.workflow_execution_id.as_str()) {
                return Err(CliErrorKind::workflow_parse(
                    "dependency fixer audit does not match the ticket workflow execution",
                )
                .into());
            }
            if let Some(existing) = dependency_fix_audit_from_body(&item.body)? {
                if existing == audit {
                    return Ok(false);
                }
                validate_dependency_fix_audit_advance(&existing, &audit)?;
            }
            item.body = render_dependency_fix_audit_body(&item.body, &audit)?;
            item.workflow.attempts = audit.current_attempt;
            item.workflow.last_error = Some(audit.failure_reason.clone());
            match audit.status {
                TaskBoardDependencyFixAutomationStatus::RetryScheduled => {
                    item.status = TaskBoardStatus::InProgress;
                    item.workflow.status = TaskBoardWorkflowStatus::Running;
                    item.workflow.current_step_id = Some("dependency_fix_retry".into());
                }
                TaskBoardDependencyFixAutomationStatus::HumanRequired => {
                    item.status = TaskBoardStatus::HumanRequired;
                    item.workflow.status = TaskBoardWorkflowStatus::Paused;
                    item.workflow.current_step_id = Some("dependency_fix_human_required".into());
                }
            }
            Ok(true)
        })
        .await?;
        Ok(())
    }
}

fn render_dependency_fix_audit_body(
    body: &str,
    audit: &TaskBoardDependencyFixAuditTrail,
) -> Result<String, CliError> {
    let json = serde_json::to_string_pretty(audit).map_err(|error| {
        CliErrorKind::workflow_parse(format!("encode dependency fixer ticket audit: {error}"))
    })?;
    let failure = serde_json::to_string(&audit.failure_reason).map_err(|error| {
        CliErrorKind::workflow_parse(format!("encode dependency fixer failure reason: {error}"))
    })?;
    let status = match audit.status {
        TaskBoardDependencyFixAutomationStatus::RetryScheduled => "retry scheduled",
        TaskBoardDependencyFixAutomationStatus::HumanRequired => "human required",
    };
    let section = format!(
        "{DEPENDENCY_FIX_AUDIT_START}\n## Dependency fix automation\n\n- Current attempt: {}\n- Recorded failures: {}\n- Status: {status}\n- Failure: {failure}\n\n```json\n{json}{DEPENDENCY_FIX_AUDIT_CLOSE}",
        audit.current_attempt, audit.attempt_count
    );
    let Some(start) = body.find(DEPENDENCY_FIX_AUDIT_START) else {
        let separator = if body.trim().is_empty() { "" } else { "\n\n" };
        return Ok(format!("{}{separator}{section}", body.trim_end()));
    };
    let suffix = &body[start..];
    let json_start = suffix.find("```json\n").ok_or_else(|| {
        CliErrorKind::workflow_parse("dependency fixer ticket audit has no JSON evidence")
    })?;
    let end_offset = suffix[json_start..]
        .find(DEPENDENCY_FIX_AUDIT_CLOSE)
        .ok_or_else(|| {
            CliErrorKind::workflow_parse("dependency fixer ticket audit section is incomplete")
        })?
        + json_start;
    let end = start + end_offset + DEPENDENCY_FIX_AUDIT_CLOSE.len();
    Ok(format!("{}{}{}", &body[..start], section, &body[end..]))
}

fn dependency_fix_audit_from_body(
    body: &str,
) -> Result<Option<TaskBoardDependencyFixAuditTrail>, CliError> {
    let Some(start) = body.find(DEPENDENCY_FIX_AUDIT_START) else {
        return Ok(None);
    };
    let suffix = &body[start + DEPENDENCY_FIX_AUDIT_START.len()..];
    let json_start = suffix.find("```json\n").ok_or_else(|| {
        CliErrorKind::workflow_parse("dependency fixer ticket audit has no JSON evidence")
    })? + "```json\n".len();
    let json_end = suffix[json_start..]
        .find(DEPENDENCY_FIX_AUDIT_CLOSE)
        .ok_or_else(|| {
            CliErrorKind::workflow_parse("dependency fixer ticket audit JSON is incomplete")
        })?
        + json_start;
    serde_json::from_str(&suffix[json_start..json_end])
        .map(Some)
        .map_err(|error| {
            CliErrorKind::workflow_parse(format!("decode dependency fixer ticket audit: {error}"))
                .into()
        })
}

fn validate_dependency_fix_audit_advance(
    existing: &TaskBoardDependencyFixAuditTrail,
    next: &TaskBoardDependencyFixAuditTrail,
) -> Result<(), CliError> {
    let scope_matches = existing.route_id == next.route_id
        && existing.board_item_id == next.board_item_id
        && existing.workflow_execution_id == next.workflow_execution_id;
    let history_advances = next.attempts.starts_with(&existing.attempts)
        && match existing.status {
            TaskBoardDependencyFixAutomationStatus::RetryScheduled => {
                next.attempt_count == existing.attempt_count.saturating_add(1)
            }
            TaskBoardDependencyFixAutomationStatus::HumanRequired => {
                next.status == TaskBoardDependencyFixAutomationStatus::RetryScheduled
                    && next.attempt_count == existing.attempt_count
            }
        };
    if !scope_matches || !history_advances {
        return Err(CliErrorKind::workflow_parse(
            "dependency fixer ticket audit conflicts with its retained history",
        )
        .into());
    }
    Ok(())
}

#[async_trait]
impl TaskBoardDependencyFixLauncher for CodexDependencyFixLauncher {
    async fn start(
        &self,
        request: &TaskBoardDependencyFixRequest,
    ) -> Result<TaskBoardDependencyFixRun, CliError> {
        let codex_request = dependency_fix_codex_request(request)?;
        let snapshot = self.controller.start_run_with_id(
            &request.session_id,
            &codex_request,
            request.dispatch_id.clone(),
        )?;
        let run = TaskBoardDependencyFixRun {
            run_id: snapshot.run_id,
            runtime: "codex".into(),
            requested_model: snapshot
                .model
                .unwrap_or_else(|| TASK_BOARD_DEPENDENCY_FIXER_MODEL.into()),
            requested_effort: snapshot
                .effort
                .unwrap_or_else(|| TASK_BOARD_DEPENDENCY_FIXER_EFFORT.into()),
            attempt: request.attempt,
            started_at: snapshot.created_at,
            failure_evidence_id: request
                .retry_evidence
                .as_ref()
                .map(|evidence| evidence.evidence_id.clone()),
        };
        schedule_dependency_fix_deadline(
            self.controller.clone(),
            request.clone(),
            run.clone(),
            dependency_fix_deadline(request, &run.started_at)?,
        );
        Ok(run)
    }
}

fn dependency_fix_deadline(
    request: &TaskBoardDependencyFixRequest,
    started_at: &str,
) -> Result<DateTime<Utc>, CliError> {
    let raw = request
        .audit
        .as_ref()
        .map_or_else(|| started_at, |audit| audit.deadline_at.as_str());
    let parsed = DateTime::parse_from_rfc3339(raw).map_err(|error| {
        CliErrorKind::workflow_parse(format!("dependency fixer deadline is invalid: {error}"))
    })?;
    let mut deadline = parsed.with_timezone(&Utc);
    if request.audit.is_none() {
        let budget = TimeDelta::try_seconds(
            i64::try_from(request.attempt_policy.max_elapsed_seconds).map_err(|_| {
                CliErrorKind::workflow_parse("dependency fixer budget is out of range")
            })?,
        )
        .ok_or_else(|| CliErrorKind::workflow_parse("dependency fixer budget is out of range"))?;
        deadline = deadline.checked_add_signed(budget).ok_or_else(|| {
            CliErrorKind::workflow_parse("dependency fixer deadline is out of range")
        })?;
    }
    Ok(deadline)
}

fn schedule_dependency_fix_deadline(
    controller: CodexControllerHandle,
    request: TaskBoardDependencyFixRequest,
    run: TaskBoardDependencyFixRun,
    deadline: DateTime<Utc>,
) {
    tokio::spawn(async move {
        let remaining = deadline
            .signed_duration_since(Utc::now())
            .to_std()
            .unwrap_or_default();
        tokio::time::sleep(remaining).await;
        if let Err(error) = enforce_dependency_fix_deadline(controller, request, run).await {
            tracing::error!(%error, "failed to enforce dependency fixer deadline");
        }
    });
}

async fn enforce_dependency_fix_deadline(
    controller: CodexControllerHandle,
    request: TaskBoardDependencyFixRequest,
    run: TaskBoardDependencyFixRun,
) -> Result<(), CliError> {
    if !controller.run(&run.run_id)?.status.is_active() {
        return Ok(());
    }
    let run_id = run.run_id.clone();
    let stopped = tokio::task::spawn_blocking({
        let controller = controller.clone();
        move || controller.stop(&run_id)
    })
    .await
    .map_err(|_| CliErrorKind::workflow_io("join dependency fixer deadline cancellation"))??;
    if stopped.status != CodexRunStatus::Cancelled {
        return Ok(());
    }
    let completed_at = Utc::now().to_rfc3339();
    let audit = task_board_dependency_fix_timeout_audit(&request, &run, &completed_at)?;
    let sink = controller.dependency_fix_audit_sink()?;
    TaskBoardDependencyFixAuditSink::record(sink.as_ref(), &audit).await
}

fn dependency_fix_codex_request(
    request: &TaskBoardDependencyFixRequest,
) -> Result<CodexRunRequest, CliError> {
    Ok(CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt: render_task_board_dependency_fix_prompt(request)?,
        mode: CodexRunMode::WorkspaceWrite,
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: vec![
            "task-board".into(),
            format!("task-board:item:{}", request.board_item_id),
            "task-board:workflow:write".into(),
            format!("task-board:attempt:{}", request.dispatch_id),
        ],
        name: Some(format!(
            "Dependency Fix: {}#{}",
            request.repository, request.pull_request_number
        )),
        persona: None,
        resume_thread_id: None,
        task_id: None,
        board_item_id: Some(request.board_item_id.clone()),
        workflow_execution_id: Some(request.workflow_execution_id.clone()),
        model: Some(TASK_BOARD_DEPENDENCY_FIXER_MODEL.into()),
        effort: Some(TASK_BOARD_DEPENDENCY_FIXER_EFFORT.into()),
        allow_custom_model: false,
    })
}

#[cfg(test)]
mod tests {
    use harness_task_board::{
        TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck,
        TaskBoardDependencyCheckState, TaskBoardDependencyConflictEvidence,
        TaskBoardDependencyConflictState, TaskBoardDependencyIdentity,
        TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageResult,
        TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
    };

    use super::*;

    const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

    #[test]
    fn codex_request_is_write_scoped_and_pinned_to_spark_low() {
        let request = dependency_fix_request();
        let codex = dependency_fix_codex_request(&request).expect("Codex request");

        assert_eq!(codex.mode, CodexRunMode::WorkspaceWrite);
        assert_eq!(TASK_BOARD_DEPENDENCY_FIXER_MODEL, "gpt-5.3-codex-spark");
        assert_eq!(
            codex.model.as_deref(),
            Some(TASK_BOARD_DEPENDENCY_FIXER_MODEL)
        );
        assert_eq!(TASK_BOARD_DEPENDENCY_FIXER_EFFORT, "low");
        assert_eq!(
            codex.effort.as_deref(),
            Some(TASK_BOARD_DEPENDENCY_FIXER_EFFORT)
        );
        assert_eq!(codex.board_item_id.as_deref(), Some("item-1"));
        assert_eq!(codex.workflow_execution_id.as_deref(), Some("execution-1"));
        assert!(codex.prompt.contains(HEAD));
        assert!(codex.prompt.contains("\"checks\""));
    }

    #[test]
    fn initial_deadline_uses_the_requests_policy_budget() {
        let mut request = dependency_fix_request();
        request.attempt_policy.max_elapsed_seconds = 300;

        let deadline =
            dependency_fix_deadline(&request, "2026-07-30T10:00:00Z").expect("policy deadline");

        assert_eq!(deadline.to_rfc3339(), "2026-07-30T10:05:00+00:00");
    }

    fn dependency_fix_request() -> TaskBoardDependencyFixRequest {
        TaskBoardDependencyFixRequest {
            dispatch_id: "route-1:fix".into(),
            route_id: "route-1".into(),
            session_id: "session-1".into(),
            board_item_id: "item-1".into(),
            workflow_execution_id: "execution-1".into(),
            attempt: 1,
            attempt_policy: harness_task_board::TaskBoardDependencyFixAttemptPolicy::default(),
            repository: "acme/widgets".into(),
            pull_request_number: 17,
            exact_head_revision: HEAD.into(),
            requested_repair: "repair the failing build".into(),
            retry_evidence: None,
            audit: None,
            triage_result: TaskBoardDependencyTriageResult {
                schema_version: 1,
                repository: "acme/widgets".into(),
                pull_request_number: 17,
                exact_head_revision: HEAD.into(),
                dependency: TaskBoardDependencyIdentity {
                    name: "serde".into(),
                    ecosystem: "cargo".into(),
                    current_version: "1.0.0".into(),
                    target_version: "1.0.1".into(),
                    update_class: TaskBoardDependencyUpdateClass::Patch,
                },
                checks: vec![TaskBoardDependencyCheck {
                    name: "test".into(),
                    state: TaskBoardDependencyCheckState::Failed,
                    details_url: Some("https://example.test/check/1".into()),
                }],
                conflicts: TaskBoardDependencyConflictEvidence {
                    state: TaskBoardDependencyConflictState::Clean,
                    summary: "clean".into(),
                },
                approvals: TaskBoardDependencyApprovalEvidence {
                    current: 1,
                    required: 1,
                },
                safety_assumption: "the exact-head evidence is current".into(),
                disposition: TaskBoardDependencyTriageDisposition::FixRequired,
                required_tools: vec!["task_board.audit".into(), "codex.dispatch".into()],
                next_steps: vec![
                    TaskBoardDependencyTriageStep {
                        order: 1,
                        action: "record_result".into(),
                        reason: "retain the triage decision".into(),
                    },
                    TaskBoardDependencyTriageStep {
                        order: 2,
                        action: "dispatch_fixer".into(),
                        reason: "repair the failing build".into(),
                    },
                ],
            },
        }
    }
}
