use std::time::Duration;

use tokio::time::timeout;

use crate::daemon::agent_tui::AgentTuiStatus;
use crate::daemon::protocol::{CodexRunStatus, ManagedAgentSnapshot};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::SessionRole;
use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardLocalAttemptResult, TaskBoardReadOnlyRunContext, TaskBoardReadOnlyWorkflowLaunch,
    TaskBoardResolvedReviewer, TaskBoardReviewerProfile, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWriteWorkflowLaunch, bind_plan_approval,
    build_planning_result,
};

use super::test_support::{
    applied_task, codex_snapshot, seed_session, terminal_snapshot, test_http_state,
};
use super::{
    begin_worker_compensation, codex_worker_id, codex_worker_request, exact_worker_not_found,
    managed_admission_owner_id, managed_worker_id, recover_same_applied_worker,
    resolve_start_failure, start_worker_for_applied_task, stop_worker_in_lane, terminal_worker_id,
    terminal_worker_request,
};

#[test]
fn codex_worker_request_carries_task_board_identity() {
    let applied = applied_task(AgentMode::Headless);

    let request = codex_worker_request(&applied, "codex-dispatch-intent-1");

    assert_eq!(request.task_id.as_deref(), Some("task-1"));
    assert_eq!(request.board_item_id.as_deref(), Some("board-1"));
    assert_eq!(request.workflow_execution_id.as_deref(), Some("workflow-1"));
    assert_eq!(request.role, SessionRole::Leader);
    assert_eq!(request.fallback_role, Some(SessionRole::Worker));
    assert!(
        request
            .capabilities
            .contains(&"task-board:item:board-1".to_string())
    );
    assert!(request.prompt.contains("Session task: task-1"));
    assert!(request.prompt.contains("Session id:\nsession-1"));
    assert!(request.prompt.contains("Tags:\nbackend"));
    assert!(request.prompt.contains("Worktree:\n/tmp/task-worktree"));
    assert!(request.prompt.contains("External refs:\ngithub:123"));
    assert!(
        request
            .prompt
            .contains("Managed run id:\ncodex-dispatch-intent-1")
    );
    assert!(
        request
            .prompt
            .contains("harness session task list session-1 --json")
    );
    assert!(
        request
            .prompt
            .contains("harness session task submit-for-review session-1 task-1")
    );
    assert!(request.prompt.contains("authoritative safety net"));
}

#[test]
fn planning_and_evaluate_workers_are_report_only() {
    for mode in [AgentMode::Planning, AgentMode::Evaluate] {
        let applied = applied_task(mode);
        let request = codex_worker_request(&applied, "codex-read-only");

        assert_eq!(request.mode, crate::daemon::protocol::CodexRunMode::Report);
    }
}

#[test]
fn read_only_review_request_freezes_identity_and_has_no_session_task() {
    let mut applied = applied_task(AgentMode::Evaluate);
    applied.item.workflow_kind = TaskBoardWorkflowKind::Review;
    applied.read_only_workflow = Some(review_launch());

    let request = codex_worker_request(&applied, "codex-review-attempt");

    assert_eq!(request.mode, crate::daemon::protocol::CodexRunMode::Report);
    assert_eq!(request.task_id, None);
    assert_eq!(request.persona.as_deref(), Some("code-reviewer"));
    assert_eq!(request.model.as_deref(), Some("gpt-5"));
    assert_eq!(request.effort.as_deref(), Some("high"));
    assert_eq!(request.workflow_execution_id.as_deref(), Some("workflow-1"));
    assert!(request.prompt.contains("Exact head: head-frozen"));
    assert!(request.prompt.contains("Do not modify files"));
    let (_, encoded) = request
        .prompt
        .split_once("shape (use verdict pass, changes_required, or human_required):\n")
        .expect("result envelope marker");
    let envelope: TaskBoardLocalAttemptResult =
        serde_json::from_str(encoded).expect("strict result envelope");
    assert_eq!(envelope.execution_id, "workflow-1");
    assert_eq!(envelope.action_key, "review:default-code-reviewer");
    assert_eq!(envelope.attempt, 1);
    assert_eq!(envelope.idempotency_key, "codex-review-attempt");
    assert_eq!(envelope.exact_head_revision, "head-frozen");
    assert!(matches!(
        envelope.artifact,
        TaskBoardAttemptResultArtifact::Review(_)
    ));
    assert!(
        request
            .capabilities
            .contains(&"task-board:workflow:read-only".to_string())
    );
    assert_eq!(
        managed_admission_owner_id(&applied, "dispatch-intent-1"),
        "workflow-workflow-1"
    );
}

#[test]
fn write_implementation_request_freezes_approved_plan_and_result_identity() {
    let mut applied = applied_task(AgentMode::Headless);
    applied.write_workflow = Some(Box::new(write_launch()));

    let request = codex_worker_request(&applied, "codex-implementation-attempt");

    assert_eq!(
        request.mode,
        crate::daemon::protocol::CodexRunMode::WorkspaceWrite
    );
    assert_eq!(request.task_id.as_deref(), Some("task-1"));
    assert!(request.prompt.contains("Base head: head-base"));
    assert!(request.prompt.contains("Implement the approved change."));
    assert!(request.prompt.contains("Focused tests pass"));
    let (_, encoded) = request
        .prompt
        .split_once("identity and shape:\n")
        .expect("result envelope marker");
    let envelope: TaskBoardLocalAttemptResult =
        serde_json::from_str(encoded).expect("strict result envelope");
    assert_eq!(envelope.execution_id, "workflow-1");
    assert_eq!(envelope.action_key, "implementation:1");
    assert_eq!(envelope.idempotency_key, "codex-implementation-attempt");
    assert!(matches!(
        envelope.artifact,
        TaskBoardAttemptResultArtifact::Implementation(_)
    ));
    assert!(
        request
            .capabilities
            .contains(&"task-board:workflow:write".to_string())
    );
    assert_eq!(
        managed_admission_owner_id(&applied, "dispatch-intent-1"),
        "workflow-workflow-1"
    );
}

#[test]
fn ordinary_dispatch_keeps_worker_scoped_admission() {
    let applied = applied_task(AgentMode::Headless);

    assert_eq!(
        managed_admission_owner_id(&applied, "dispatch-intent-1"),
        managed_worker_id(&applied, "dispatch-intent-1")
    );
}

#[test]
fn interactive_worker_request_uses_terminal_runtime() {
    let applied = applied_task(AgentMode::Interactive);

    let request = terminal_worker_request(&applied, "agent-tui-dispatch-intent-1");

    assert_eq!(request.runtime, "codex");
    assert_eq!(request.task_id.as_deref(), Some("task-1"));
    assert_eq!(request.board_item_id.as_deref(), Some("board-1"));
    assert_eq!(request.role, SessionRole::Leader);
    assert_eq!(request.fallback_role, Some(SessionRole::Worker));
    assert_eq!(request.rows, 24);
    assert_eq!(request.cols, 80);
}

fn review_launch() -> TaskBoardReadOnlyWorkflowLaunch {
    let mut profile = TaskBoardReviewerProfile::default();
    profile.model = Some("gpt-5".into());
    profile.effort = Some("high".into());
    TaskBoardReadOnlyWorkflowLaunch {
        workflow_kind: TaskBoardWorkflowKind::Review,
        execution_repository: None,
        configuration_revision: 1,
        policy_version: "policy-v1".into(),
        resolved_reviewers: TaskBoardResolvedReviewer {
            reviewer_count: 1,
            required_approvals: 1,
            max_revision_cycles: 1,
            profiles: vec![profile],
        },
        source_item_revision: 1,
        prepared_item_revision: 2,
        run_context: TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: "session-1".into(),
            title: "Board item".into(),
            body: "Investigate the issue".into(),
            tags: vec!["backend".into()],
            worktree: "/tmp/task-worktree".into(),
        },
        provider_revision: None,
        pull_request: None,
        exact_head_revision: "head-frozen".into(),
    }
}

fn write_launch() -> TaskBoardWriteWorkflowLaunch {
    let reviewer = TaskBoardResolvedReviewer {
        reviewer_count: 1,
        required_approvals: 1,
        max_revision_cycles: 3,
        profiles: vec![TaskBoardReviewerProfile::default()],
    };
    let snapshot = TaskBoardWorkflowSnapshot {
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
        execution_repository: None,
        item_revision: 3,
        configuration_revision: 1,
        policy_version: "policy-v1".into(),
        reviewer: reviewer.clone(),
        read_only_run_context: None,
        provider_revision: None,
    };
    let planning_result = build_planning_result(
        "# Plan\n\nImplement the approved change.",
        ["Focused tests pass".into()],
        &snapshot,
        "workflow-1",
    )
    .expect("build plan");
    let plan_approval = bind_plan_approval(
        &planning_result,
        &snapshot,
        "workflow-1",
        "lead",
        "2026-07-18T10:00:00Z",
    )
    .expect("bind approval");
    TaskBoardWriteWorkflowLaunch {
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
        execution_repository: None,
        configuration_revision: 1,
        policy_version: "policy-v1".into(),
        resolved_reviewers: reviewer,
        source_item_revision: 1,
        prepared_item_revision: 2,
        provider_revision: None,
        pull_request: None,
        base_head_revision: "head-base".into(),
        planning_result,
        plan_approval,
    }
}

#[test]
fn worker_identity_is_stable_for_reclaimed_dispatch_claims() {
    assert_eq!(
        codex_worker_id("dispatch-intent-1"),
        codex_worker_id("dispatch-intent-1")
    );
    assert_eq!(
        terminal_worker_id("dispatch-intent-1"),
        terminal_worker_id("dispatch-intent-1")
    );
    assert_ne!(
        codex_worker_id("dispatch-intent-1"),
        codex_worker_id("dispatch-intent-2")
    );
}

#[test]
fn terminal_and_failed_same_session_workers_are_recovered() {
    let snapshots = [
        ManagedAgentSnapshot::Terminal(terminal_snapshot(AgentTuiStatus::Stopped, "session-1")),
        ManagedAgentSnapshot::Codex(codex_snapshot(CodexRunStatus::Failed, "session-1")),
    ];

    for snapshot in snapshots {
        let expected_id = snapshot.agent_id().to_string();
        let applied = applied_task(AgentMode::Headless);
        let recovered = resolve_start_failure(start_failure(), Ok(Some(snapshot)), &applied)
            .expect("same-session durable worker evidence");
        assert_eq!(recovered.agent_id(), expected_id);
    }
}

#[test]
fn deterministic_worker_from_another_session_fails_closed() {
    let snapshot =
        ManagedAgentSnapshot::Codex(codex_snapshot(CodexRunStatus::Running, "different-session"));

    let applied = applied_task(AgentMode::Headless);
    let error = recover_same_applied_worker(snapshot, &applied)
        .expect_err("cross-session deterministic identity must conflict");

    assert_eq!(error.code(), "KSRCLI092");
}

#[test]
fn read_only_recovery_rejects_a_conflicting_durable_run() {
    let mut applied = applied_task(AgentMode::Evaluate);
    applied.item.workflow_kind = TaskBoardWorkflowKind::Review;
    applied.read_only_workflow = Some(review_launch());
    let run_id = "codex-review-attempt";
    let request = codex_worker_request(&applied, run_id);
    let mut run = codex_snapshot(CodexRunStatus::Running, &applied.session_id);
    run.run_id = run_id.into();
    run.board_item_id = request.board_item_id;
    run.workflow_execution_id = request.workflow_execution_id;
    run.task_id = request.task_id;
    run.mode = request.mode;
    run.prompt = request.prompt;
    run.model = request.model;
    run.effort = request.effort;
    run.project_dir = applied
        .read_only_workflow
        .as_ref()
        .expect("read-only launch")
        .run_context
        .worktree
        .clone();
    let matching = ManagedAgentSnapshot::Codex(run.clone());

    recover_same_applied_worker(matching, &applied).expect("matching durable run");

    let mut wrong_worktree = run.clone();
    wrong_worktree.project_dir = "/tmp/other-worktree".into();
    let error = recover_same_applied_worker(ManagedAgentSnapshot::Codex(wrong_worktree), &applied)
        .expect_err("conflicting worktree must fail");
    assert_eq!(error.code(), "KSRCLI092");

    run.workflow_execution_id = Some("workflow-other".into());
    let error = recover_same_applied_worker(ManagedAgentSnapshot::Codex(run), &applied)
        .expect_err("conflicting run must fail");
    assert_eq!(error.code(), "KSRCLI092");
    assert!(error.message().contains("frozen workflow"));
}

#[test]
fn only_exact_deterministic_lookup_miss_allows_start() {
    let worker_id = codex_worker_id("dispatch-intent-1");
    let exact: CliError =
        CliErrorKind::session_not_active(format!("codex run '{worker_id}' not found")).into();
    let uncertain: CliError =
        CliErrorKind::session_not_active("codex controller not active").into();

    assert!(exact_worker_not_found(
        &exact,
        AgentMode::Headless,
        &worker_id
    ));
    assert!(!exact_worker_not_found(
        &uncertain,
        AgentMode::Headless,
        &worker_id
    ));
}

#[test]
fn uncertain_probe_errors_are_not_rollback_safe() {
    let probe_error = CliErrorKind::workflow_io("managed worker lookup failed").into();
    let applied = applied_task(AgentMode::Headless);
    let error = resolve_start_failure(start_failure(), Err(probe_error), &applied)
        .expect_err("uncertain second probe must retain recovery ownership");

    assert!(!error.may_rollback());
    assert_eq!(error.into_cli_error().code(), "WORKFLOW_IO");
}

#[test]
fn exact_post_start_miss_is_rollback_safe() {
    let applied = applied_task(AgentMode::Headless);
    let error = resolve_start_failure(start_failure(), Ok(None), &applied)
        .expect_err("exact second miss preserves the start failure");

    assert!(error.may_rollback());
    assert_eq!(error.into_cli_error().code(), "WORKFLOW_IO");
}

fn start_failure() -> CliError {
    CliErrorKind::workflow_io("managed worker start failed before persistence").into()
}

#[tokio::test]
async fn worker_start_waits_for_lane_before_preflight() {
    let state = test_http_state();
    let applied = applied_task(AgentMode::Interactive);
    let intent_id = "dispatch-intent-test";
    let outer_guard = state
        .managed_agent_mutation_locks
        .lock(&applied.session_id, &managed_worker_id(&applied, intent_id))
        .await;
    let future = start_worker_for_applied_task(&state, &applied, intent_id, "stale-claim");
    tokio::pin!(future);

    assert!(
        timeout(Duration::from_millis(50), future.as_mut())
            .await
            .is_err(),
        "worker probe and preflight must wait for the deterministic worker lane",
    );

    drop(outer_guard);
    let error = timeout(Duration::from_secs(2), future)
        .await
        .expect("worker start resumes once the lane is free")
        .expect_err("test has no dispatch claim");
    assert!(error.may_rollback());
}

#[tokio::test]
async fn deterministic_worker_evidence_precedes_claim_preflight() {
    let state = test_http_state();
    let db = state.async_db.get().cloned().expect("test async db");
    let applied = applied_task(AgentMode::Headless);
    let intent_id = "dispatch-intent-reclaimed";
    let worker_id = managed_worker_id(&applied, intent_id);
    seed_session(&db, &applied.session_id).await;
    let mut snapshot = codex_snapshot(CodexRunStatus::Running, &applied.session_id);
    snapshot.run_id.clone_from(&worker_id);
    snapshot.board_item_id = Some(applied.board_item_id.clone());
    snapshot.task_id = Some(applied.work_item_id.clone());
    snapshot.workflow_execution_id = applied.item.workflow.execution_id.clone();
    snapshot.session_agent_id = None;
    db.save_codex_run(&snapshot)
        .await
        .expect("persist deterministic worker evidence");

    let recovered = start_worker_for_applied_task(&state, &applied, intent_id, "stale-claim")
        .await
        .expect("existing worker must be recovered before claim validation");

    assert_eq!(recovered.agent_id(), worker_id);
}

#[tokio::test]
async fn compensation_renews_claim_inside_worker_lane_before_stop() {
    let state = test_http_state();
    let db = state.async_db.get().cloned().expect("test async db");
    let applied = applied_task(AgentMode::Interactive);
    let intent_id = "dispatch-intent-compensation";
    let worker_id = managed_worker_id(&applied, intent_id);
    let outer_guard = state
        .managed_agent_mutation_locks
        .lock(&applied.session_id, &worker_id)
        .await;
    let future = begin_worker_compensation(
        &state,
        &db,
        &applied,
        intent_id,
        "stale-claim",
        "completion failed",
    );
    tokio::pin!(future);

    assert!(
        timeout(Duration::from_millis(50), future.as_mut())
            .await
            .is_err(),
        "compensation must wait for the deterministic worker lane",
    );

    drop(outer_guard);
    let error = timeout(Duration::from_secs(2), future)
        .await
        .expect("compensation resumes once the lane is free")
        .expect_err("stale owner must fail before stop");
    assert!(error.to_string().contains("lost its claim"));
    assert!(!error.to_string().contains("terminal agent"));
}

#[tokio::test]
async fn compensation_resume_accepts_a_worker_already_stopped_before_crash() {
    let state = test_http_state();
    let applied = applied_task(AgentMode::Interactive);
    let worker_id = managed_worker_id(&applied, "dispatch-intent-crash-resume");

    stop_worker_in_lane(&state, &applied, worker_id)
        .await
        .expect("missing deterministic worker proves the prior stop already completed");
}
