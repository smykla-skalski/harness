use serde_json::json;

use harness_kernel::errors::{CliError, CliErrorKind};

use crate::agents::turn::{
    AgentTurnFailureCategory, AgentTurnFailureStage, AgentTurnId, AgentTurnPullRequest,
    AgentTurnPullRequestContext, AgentTurnReadOnlyContent, AgentTurnRequest, AgentTurnRuntime,
    AgentTurnStatus,
};
use crate::daemon::codex_controller::CodexAgentTurnRuntime;
use crate::daemon::protocol::{CodexRunMode, CodexRunStatus};

use super::test_support::{
    codex_run_snapshot, controller_with_db, with_isolated_async_harness_env,
};
use crate::daemon::db::prelude::*;

const SESSION_ID: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";
const HEAD_REVISION: &str = "0123456789abcdef0123456789abcdef01234567";

#[tokio::test]
async fn shared_lifecycle_starts_a_codex_report_run() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, _db, _tempdir) = controller_with_db();
        let runtime = CodexAgentTurnRuntime::new(controller.clone(), SESSION_ID);
        let lifecycle: &dyn AgentTurnRuntime = &runtime;

        let id = lifecycle
            .start(AgentTurnRequest {
                prompt: "Prepare the report".into(),
                requested_model: Some("gpt-5.5".into()),
                pull_request: None,
            })
            .await
            .expect("start Codex turn");

        assert_eq!(lifecycle.runtime(), "codex");
        assert_eq!(
            lifecycle.status(&id).await.expect("queued status"),
            AgentTurnStatus::Queued
        );
        let snapshot = controller.run(id.as_str()).expect("load Codex run");
        assert_eq!(snapshot.mode, CodexRunMode::Report);
        assert_eq!(snapshot.prompt, "Prepare the report");
        assert_eq!(snapshot.model.as_deref(), Some("gpt-5.5"));
    })
    .await;
}

#[tokio::test]
async fn unsupported_codex_model_uses_shared_start_failure() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, _db, _tempdir) = controller_with_db();
        let runtime = CodexAgentTurnRuntime::new(controller, SESSION_ID);
        let error = runtime
            .start(AgentTurnRequest {
                prompt: "Prepare the report".into(),
                requested_model: Some("unsupported model".into()),
                pull_request: None,
            })
            .await
            .expect_err("unsupported model must fail");

        let failure = runtime.classify_error(AgentTurnFailureStage::Start, &error);
        assert_eq!(failure.category, AgentTurnFailureCategory::UnsupportedModel);
        assert_eq!(failure.stage, AgentTurnFailureStage::Start);
        assert!(!failure.automatic_retry_safe);
    })
    .await;
}

#[tokio::test]
async fn completed_codex_turn_returns_one_stable_report() {
    let (controller, db, _tempdir) = controller_with_db();
    let mut snapshot = report_snapshot(CodexRunStatus::Completed);
    snapshot.final_message = Some("Complete Codex report".into());
    snapshot.model = Some("gpt-5.3-codex-spark".into());
    super::super::handle::record_snapshot_event(
        &mut snapshot,
        "source/bound",
        "Bound pull request source".into(),
        &json!({
            "repository": "smykla-skalski/harness",
            "pullRequestNumber": 894,
            "headRevision": HEAD_REVISION,
            "readOnly": true
        }),
    );
    super::super::handle::record_snapshot_event(
        &mut snapshot,
        "thread/start",
        "Codex thread ready".into(),
        &json!({
            "thread": { "id": "thread-1" },
            "model": "gpt-5.3-codex-spark"
        }),
    );
    super::super::handle::record_snapshot_event(
        &mut snapshot,
        "source/bound",
        "Observed a later pull request head".into(),
        &json!({
            "repository": "smykla-skalski/harness",
            "pullRequestNumber": 894,
            "headRevision": "ffffffffffffffffffffffffffffffffffffffff",
            "readOnly": true
        }),
    );
    db.lock()
        .expect("db lock")
        .save_codex_run(&snapshot)
        .expect("save completed run");
    let runtime = CodexAgentTurnRuntime::new(controller, SESSION_ID);
    let id = AgentTurnId::new(snapshot.run_id).expect("turn id");

    let result = runtime
        .result(&id)
        .await
        .expect("load result")
        .expect("completed result");
    assert_eq!(result.correlation_id, id);
    assert_eq!(result.report, "Complete Codex report");
    assert_eq!(result.stop_reason, "end_turn");
    assert_eq!(
        result.requested_model.as_deref(),
        Some("gpt-5.3-codex-spark")
    );
    assert_eq!(
        result.effective_model.as_deref(),
        Some("gpt-5.3-codex-spark")
    );
    assert_eq!(result.source_revision.as_deref(), Some(HEAD_REVISION));
    assert_eq!(
        runtime.result(&id).await.expect("reload result"),
        Some(result)
    );
    assert_eq!(
        runtime.cancel(&id).await.expect("cancel completed turn"),
        AgentTurnStatus::Completed
    );
}

#[tokio::test]
async fn source_bound_codex_turn_persists_exact_read_only_context_before_work() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, _db, _tempdir) = controller_with_db();
        let runtime = CodexAgentTurnRuntime::new(controller.clone(), SESSION_ID);

        let id = runtime
            .start(AgentTurnRequest {
                prompt: "Review the supplied changes".into(),
                requested_model: Some("gpt-5.5".into()),
                pull_request: Some(pull_request_context(HEAD_REVISION)),
            })
            .await
            .expect("start source-bound Codex turn");

        let snapshot = controller.run(id.as_str()).expect("load Codex run");
        assert!(snapshot.prompt.contains("smykla-skalski/harness#894"));
        assert!(snapshot.prompt.contains(HEAD_REVISION));
        assert!(snapshot.prompt.contains("untrusted pull request content"));
        assert!(snapshot.prompt.contains("diff --git"));
        let source = snapshot
            .events
            .iter()
            .find(|event| event.kind == "source/bound")
            .expect("persisted source binding");
        assert_eq!(source.payload["repository"], "smykla-skalski/harness");
        assert_eq!(source.payload["pullRequestNumber"], 894);
        assert_eq!(source.payload["headRevision"], HEAD_REVISION);
        assert_eq!(source.payload["readOnly"], true);
    })
    .await;
}

#[tokio::test]
async fn mismatched_codex_context_fails_before_a_run_is_created() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, _db, _tempdir) = controller_with_db();
        let runtime = CodexAgentTurnRuntime::new(controller.clone(), SESSION_ID);
        let mut context = pull_request_context(HEAD_REVISION);
        context.content.pull_request.head_revision = "f".repeat(40);

        let error = runtime
            .start(AgentTurnRequest {
                prompt: "Review the supplied changes".into(),
                requested_model: Some("gpt-5.5".into()),
                pull_request: Some(context),
            })
            .await
            .expect_err("mismatched source must fail");

        assert_eq!(error.code(), "WORKFLOW_PARSE");
        assert!(
            controller
                .list_runs(SESSION_ID)
                .expect("list Codex runs")
                .runs
                .is_empty()
        );
    })
    .await;
}

#[tokio::test]
async fn codex_cancellation_uses_the_shared_terminal_state() {
    let (controller, db, _tempdir) = controller_with_db();
    let snapshot = report_snapshot(CodexRunStatus::Running);
    db.lock()
        .expect("db lock")
        .save_codex_run(&snapshot)
        .expect("save running run");
    let runtime = CodexAgentTurnRuntime::new(controller, SESSION_ID);
    let id = AgentTurnId::new(snapshot.run_id).expect("turn id");

    assert_eq!(
        runtime.cancel(&id).await.expect("cancel running turn"),
        AgentTurnStatus::Cancelled
    );
    assert_eq!(
        runtime.cancel(&id).await.expect("cancel again"),
        AgentTurnStatus::Cancelled
    );
    assert!(runtime.result(&id).await.expect("load result").is_none());
    let failure = runtime
        .failure(&id)
        .await
        .expect("load cancellation")
        .expect("cancelled failure");
    assert_eq!(failure.category, AgentTurnFailureCategory::Cancelled);
    assert_eq!(failure.stage, AgentTurnFailureStage::Cancellation);
    assert!(!failure.automatic_retry_safe);
}

#[tokio::test]
async fn failed_codex_turns_use_shared_recovery_categories() {
    let (controller, db, _tempdir) = controller_with_db();
    let runtime = CodexAgentTurnRuntime::new(controller, SESSION_ID);
    let mismatch_error = CliError::from(CliErrorKind::workflow_parse(
        "codex app-server model mismatch: unsupported model selection: requested \
         'gpt-5.3-codex-spark', effective 'gpt-5.5'",
    ))
    .to_string();
    let cases = [
        (
            "HTTP 401 unauthorized".to_string(),
            AgentTurnFailureCategory::Authentication,
            false,
            AgentTurnFailureStage::Execution,
        ),
        (
            "HTTP 429 rate limit".to_string(),
            AgentTurnFailureCategory::RateLimited,
            true,
            AgentTurnFailureStage::Execution,
        ),
        (
            "unsupported model gpt-x".to_string(),
            AgentTurnFailureCategory::UnsupportedModel,
            false,
            AgentTurnFailureStage::Execution,
        ),
        (
            mismatch_error,
            AgentTurnFailureCategory::UnsupportedModel,
            false,
            AgentTurnFailureStage::Start,
        ),
        (
            "connection closed".to_string(),
            AgentTurnFailureCategory::Transport,
            false,
            AgentTurnFailureStage::Execution,
        ),
        (
            "provider refused prompt".to_string(),
            AgentTurnFailureCategory::ProviderRejected,
            false,
            AgentTurnFailureStage::Execution,
        ),
        (
            "unrecognized failure".to_string(),
            AgentTurnFailureCategory::Unknown,
            false,
            AgentTurnFailureStage::Execution,
        ),
    ];

    for (sequence, (detail, category, retry_safe, stage)) in cases.into_iter().enumerate() {
        let mut snapshot = report_snapshot(CodexRunStatus::Failed);
        snapshot.run_id = format!("codex-failure-{sequence}");
        snapshot.error = Some(detail.clone());
        db.lock()
            .expect("db lock")
            .save_codex_run(&snapshot)
            .expect("save failed run");
        let id = AgentTurnId::new(snapshot.run_id).expect("turn id");
        let failure = runtime
            .failure(&id)
            .await
            .expect("load failure")
            .expect("failed turn failure");
        assert_eq!(failure.category, category, "{detail}");
        assert_eq!(failure.stage, stage);
        assert_eq!(failure.automatic_retry_safe, retry_safe, "{detail}");
    }
}

#[tokio::test]
async fn codex_failure_detail_redacts_credentials() {
    let (controller, db, _tempdir) = controller_with_db();
    let mut snapshot = report_snapshot(CodexRunStatus::Failed);
    snapshot.error = Some("connection closed token=super-secret".into());
    db.lock()
        .expect("db lock")
        .save_codex_run(&snapshot)
        .expect("save failed run");
    let runtime = CodexAgentTurnRuntime::new(controller, SESSION_ID);
    let id = AgentTurnId::new(snapshot.run_id).expect("turn id");

    let failure = runtime
        .failure(&id)
        .await
        .expect("load failure")
        .expect("failed turn failure");
    assert_eq!(failure.category, AgentTurnFailureCategory::Transport);
    assert!(!failure.detail.contains("super-secret"));
}

#[tokio::test]
async fn codex_turn_ids_remain_scoped_to_the_bound_session() {
    let (controller, db, _tempdir) = controller_with_db();
    let mut snapshot = report_snapshot(CodexRunStatus::Running);
    snapshot.session_id = "another-session".into();
    db.lock()
        .expect("db lock")
        .save_codex_run(&snapshot)
        .expect("save other session run");
    let runtime = CodexAgentTurnRuntime::new(controller.clone(), SESSION_ID);
    let id = AgentTurnId::new(snapshot.run_id).expect("turn id");

    let error = runtime
        .cancel(&id)
        .await
        .expect_err("other session turn must be rejected");
    assert_eq!(error.code(), "SESSION_SCOPE_DENIED");
    assert!(error.to_string().contains("does not belong"));
    assert_eq!(
        controller
            .load_run(id.as_str())
            .expect("load untouched run")
            .status,
        CodexRunStatus::Running
    );
}

#[tokio::test]
async fn non_report_codex_runs_are_rejected_by_the_shared_lifecycle() {
    let (controller, db, _tempdir) = controller_with_db();
    let snapshot = codex_run_snapshot(CodexRunStatus::Running);
    db.lock()
        .expect("db lock")
        .save_codex_run(&snapshot)
        .expect("save workspace-write run");
    let runtime = CodexAgentTurnRuntime::new(controller.clone(), SESSION_ID);
    let id = AgentTurnId::new(snapshot.run_id).expect("turn id");

    let error = runtime
        .cancel(&id)
        .await
        .expect_err("workspace-write run must be rejected");
    assert!(error.to_string().contains("is not a report run"));
    assert_eq!(
        controller
            .load_run(id.as_str())
            .expect("load untouched run")
            .status,
        CodexRunStatus::Running
    );
}

fn report_snapshot(status: CodexRunStatus) -> crate::daemon::protocol::CodexRunSnapshot {
    let mut snapshot = codex_run_snapshot(status);
    snapshot.mode = CodexRunMode::Report;
    snapshot.pending_approvals.clear();
    snapshot
}

fn pull_request_context(head_revision: &str) -> AgentTurnPullRequestContext {
    let pull_request = AgentTurnPullRequest {
        repository: "smykla-skalski/harness".into(),
        number: 894,
        head_revision: head_revision.into(),
    };
    AgentTurnPullRequestContext {
        pull_request: pull_request.clone(),
        content: AgentTurnReadOnlyContent {
            pull_request,
            body: "diff --git a/src/lib.rs b/src/lib.rs".into(),
        },
    }
}
