//! Review transport daemon-routing coverage.
//!
//! Worker lifecycle mutations (`checkpoint`, `submit-for-review`) plus the
//! remaining review commands and `improver apply` must prefer the daemon
//! client when a running daemon is reachable. The existing `review_cli`
//! integration tests only exercise the file-backed fallback, so deleting the
//! `DaemonClient::try_connect()` branch from each command would go
//! unnoticed. These tests stand up a fake running daemon via
//! `install_fake_running_xdg_daemon`, run each `Execute::execute()`
//! end-to-end, and assert the exact request path and JSON body sent.

mod fake_daemon;

use tempfile::tempdir;

use harness::session::service;
use harness::session::transport::{
    SessionImproverApplyArgs, TaskArbitrateArgs, TaskCheckpointArgs, TaskClaimReviewArgs,
    TaskListArgs, TaskRespondReviewArgs, TaskSubmitForReviewArgs, TaskSubmitReviewArgs,
};
use harness::session::types::{ReviewVerdict, TaskSeverity, TaskSource, TaskStatus};
use harness_workspace::command_context::{AppContext, Execute};

use fake_daemon::{
    assert_rejected_before_any_request_reaches_daemon, run_against_fake_daemon,
    run_improver_against_fake_daemon,
};

#[test]
fn task_list_routes_through_daemon_client() {
    let captured = run_against_fake_daemon("00000000-0000-4000-8000-00000000afff", || {
        let args = TaskListArgs {
            session_id: "00000000-0000-4000-8000-00000000afff".into(),
            status: Some(TaskStatus::InProgress),
            json: true,
            project_dir: None,
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000afff"
    );
}

#[test]
fn task_list_rejects_a_session_id_that_would_escape_its_path_segment() {
    assert_rejected_before_any_request_reaches_daemon(|| {
        let args = TaskListArgs {
            session_id: "../orchestrator/stop".into(),
            status: None,
            json: true,
            project_dir: None,
        };
        let error = args.execute(&AppContext).expect_err(
            "a session id with a path separator must be rejected before any request is sent",
        );
        assert!(error.to_string().contains("../orchestrator/stop"));
    });
}

#[test]
fn checkpoint_args_route_through_daemon_client() {
    let captured = run_against_fake_daemon("00000000-0000-4000-8000-00000000a000", || {
        let args = TaskCheckpointArgs {
            session_id: "00000000-0000-4000-8000-00000000a000".into(),
            task_id: "task-1".into(),
            actor: "worker-1".into(),
            summary: "halfway".into(),
            progress: 50,
            project_dir: None,
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000a000/tasks/task-1/checkpoint"
    );
    assert!(captured.body.contains("\"actor\":\"worker-1\""));
    assert!(captured.body.contains("\"progress\":50"));
}

#[test]
fn checkpoint_args_reject_a_task_id_that_would_escape_its_path_segment() {
    assert_rejected_before_any_request_reaches_daemon(|| {
        let args = TaskCheckpointArgs {
            session_id: "00000000-0000-4000-8000-00000000a010".into(),
            task_id: "foo/../bar".into(),
            actor: "worker-1".into(),
            summary: "halfway".into(),
            progress: 50,
            project_dir: None,
        };
        let error = args.execute(&AppContext).expect_err(
            "a task id with a path separator must be rejected before any request is sent",
        );
        assert!(error.to_string().contains("foo/../bar"));
    });
}

#[test]
fn submit_for_review_args_routes_through_daemon_client() {
    // Silence unused import when a subset of tests is selected.
    let _ = (TaskSeverity::Medium, TaskSource::Manual);
    let captured = run_against_fake_daemon("00000000-0000-4000-8000-00000000a001", || {
        let args = TaskSubmitForReviewArgs {
            session_id: "00000000-0000-4000-8000-00000000a001".into(),
            task_id: "task-1".into(),
            actor: "worker-1".into(),
            summary: Some("done".into()),
            suggested_persona: Some("code-reviewer".into()),
            project_dir: None,
        };
        let exit = args.execute(&AppContext).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000a001/tasks/task-1/submit-for-review"
    );
    assert!(
        captured.body.contains("\"actor\":\"worker-1\""),
        "body must carry actor: {}",
        captured.body
    );
    assert!(
        captured
            .body
            .contains("\"suggested_persona\":\"code-reviewer\""),
        "body must carry persona hint: {}",
        captured.body
    );
}

#[test]
fn claim_review_args_routes_through_daemon_client() {
    let captured = run_against_fake_daemon("00000000-0000-4000-8000-00000000a002", || {
        let args = TaskClaimReviewArgs {
            session_id: "00000000-0000-4000-8000-00000000a002".into(),
            task_id: "task-1".into(),
            actor: "rev-1".into(),
            project_dir: None,
        };
        let exit = args.execute(&AppContext).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000a002/tasks/task-1/claim-review"
    );
    assert!(captured.body.contains("\"actor\":\"rev-1\""));
}

#[test]
fn submit_review_args_routes_through_daemon_client() {
    let captured = run_against_fake_daemon("00000000-0000-4000-8000-00000000a003", || {
        let args = TaskSubmitReviewArgs {
            session_id: "00000000-0000-4000-8000-00000000a003".into(),
            task_id: "task-1".into(),
            actor: "rev-1".into(),
            verdict: ReviewVerdict::RequestChanges,
            summary: "needs work".into(),
            points: Some(r#"[{"point_id":"p1","text":"fix","state":"open"}]"#.into()),
            project_dir: None,
        };
        let exit = args.execute(&AppContext).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000a003/tasks/task-1/submit-review"
    );
    assert!(
        captured.body.contains("\"verdict\":\"request_changes\""),
        "body must serialize snake_case verdict: {}",
        captured.body
    );
    assert!(
        captured.body.contains("\"point_id\":\"p1\""),
        "body must include parsed review points: {}",
        captured.body
    );
}

#[test]
fn respond_review_args_routes_through_daemon_client() {
    let captured = run_against_fake_daemon("00000000-0000-4000-8000-00000000a004", || {
        let args = TaskRespondReviewArgs {
            session_id: "00000000-0000-4000-8000-00000000a004".into(),
            task_id: "task-1".into(),
            actor: "worker-1".into(),
            agreed: vec!["p1".into()],
            disputed: vec!["p2".into(), "p3".into()],
            note: Some("reworking".into()),
            project_dir: None,
        };
        let exit = args.execute(&AppContext).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000a004/tasks/task-1/respond-review"
    );
    assert!(captured.body.contains("\"agreed\":[\"p1\"]"));
    assert!(captured.body.contains("\"disputed\":[\"p2\",\"p3\"]"));
}

#[test]
fn arbitrate_args_routes_through_daemon_client() {
    let captured = run_against_fake_daemon("00000000-0000-4000-8000-00000000a005", || {
        let args = TaskArbitrateArgs {
            session_id: "00000000-0000-4000-8000-00000000a005".into(),
            task_id: "task-1".into(),
            actor: "leader".into(),
            verdict: ReviewVerdict::Approve,
            summary: "shipping".into(),
            project_dir: None,
        };
        let exit = args.execute(&AppContext).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000a005/tasks/task-1/arbitrate"
    );
    assert!(captured.body.contains("\"verdict\":\"approve\""));
    assert!(captured.body.contains("\"summary\":\"shipping\""));
}

#[test]
fn improver_apply_args_routes_through_daemon_client() {
    let tmp = tempdir().expect("tempdir for contents");
    let contents_path = tmp.path().join("new.md");
    std::fs::write(&contents_path, "new contents\n").expect("write contents");

    let captured = run_improver_against_fake_daemon(|| {
        let args = SessionImproverApplyArgs {
            session_id: "00000000-0000-4000-8000-00000000a006".into(),
            actor: "improver-1".into(),
            issue_id: "issue/abc".into(),
            target: service::ImproverTarget::Skill,
            rel_path: "demo/SKILL.md".into(),
            new_contents_file: contents_path.to_string_lossy().to_string(),
            dry_run: true,
            project_dir: None,
        };
        let exit = args.execute(&AppContext).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000a006/improver/apply"
    );
    assert!(captured.body.contains("\"actor\":\"improver-1\""));
    assert!(captured.body.contains("\"issue_id\":\"issue/abc\""));
    assert!(captured.body.contains("\"target\":\"skill\""));
    assert!(captured.body.contains("\"rel_path\":\"demo/SKILL.md\""));
    assert!(captured.body.contains("\"dry_run\":true"));
    assert!(
        captured
            .body
            .contains("\"new_contents\":\"new contents\\n\""),
        "body must inline file contents: {}",
        captured.body
    );
}

#[test]
fn improver_apply_args_reject_a_session_id_that_would_escape_its_path_segment() {
    let tmp = tempdir().expect("tempdir for contents");
    let contents_path = tmp.path().join("new.md");
    std::fs::write(&contents_path, "new contents\n").expect("write contents");

    assert_rejected_before_any_request_reaches_daemon(|| {
        let args = SessionImproverApplyArgs {
            session_id: "../orchestrator/stop".into(),
            actor: "improver-1".into(),
            issue_id: "issue-1".into(),
            target: service::ImproverTarget::Skill,
            rel_path: "demo/SKILL.md".into(),
            new_contents_file: contents_path.to_string_lossy().to_string(),
            dry_run: true,
            project_dir: None,
        };
        let error = args.execute(&AppContext).expect_err(
            "a session id with a path separator must be rejected before any request is sent",
        );
        assert!(error.to_string().contains("../orchestrator/stop"));
    });
}
