use harness::session::service;
use harness::session::types::{AgentStatus, ReviewPoint, ReviewPointState, ReviewVerdict, TaskStatus};

use super::swarm_review_helpers::setup_two_reviewers_on_claimed_task;
use super::with_session_test_env;

fn drive_to_request_changes_consensus(
    session_id: &str,
    project: &std::path::Path,
) -> (String, String) {
    let (worker_id, task_id, gemini_id, claude_id) =
        setup_two_reviewers_on_claimed_task(session_id, project);

    let points = vec![
        ReviewPoint {
            point_id: "p1".to_string(),
            text: "tighten error handling".to_string(),
            state: ReviewPointState::Open,
            worker_note: None,
        },
        ReviewPoint {
            point_id: "p2".to_string(),
            text: "add test coverage".to_string(),
            state: ReviewPointState::Open,
            worker_note: None,
        },
    ];

    service::submit_review(
        session_id,
        &task_id,
        &gemini_id,
        ReviewVerdict::RequestChanges,
        "needs changes",
        points,
        project,
    )
    .unwrap();
    service::submit_review(
        session_id,
        &task_id,
        &claude_id,
        ReviewVerdict::Approve,
        "lgtm",
        vec![],
        project,
    )
    .unwrap();

    (worker_id, task_id)
}

#[test]
fn respond_review_all_agreed_returns_task_to_in_progress() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-respond-agree", || {
        let project = tmp.path().join("project");
        let (worker_id, task_id) = drive_to_request_changes_consensus("resp-rev-1", &project);

        service::respond_review(
            "resp-rev-1",
            &task_id,
            &worker_id,
            &["p1".to_string(), "p2".to_string()],
            &[],
            Some("will fix both"),
            &project,
        )
        .expect("respond review");

        let state = service::session_status("resp-rev-1", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::InProgress);
        assert_eq!(task.assigned_to.as_deref(), Some(worker_id.as_str()));
        assert_eq!(task.review_round, 1);
        assert!(task.consensus.is_none(), "consensus cleared after respond");
        let worker = state.agents.get(&worker_id).unwrap();
        assert_eq!(worker.status, AgentStatus::Active);
    });
}

#[test]
fn respond_review_with_disputed_points_bumps_round_and_reopens_review() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-respond-dispute", || {
        let project = tmp.path().join("project");
        let (worker_id, task_id) = drive_to_request_changes_consensus("resp-rev-2", &project);

        service::respond_review(
            "resp-rev-2",
            &task_id,
            &worker_id,
            &["p1".to_string()],
            &["p2".to_string()],
            Some("p2 is intentional"),
            &project,
        )
        .expect("respond review");

        let state = service::session_status("resp-rev-2", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::InReview);
        assert_eq!(task.review_round, 1);
        assert!(task.consensus.is_none(), "consensus cleared for next round");
        let claim = task.review_claim.as_ref().unwrap();
        assert!(
            claim.reviewers.iter().all(|e| e.submitted_at.is_none()),
            "reviewer submitted_at cleared so they re-review"
        );
    });
}

#[test]
fn respond_review_records_per_point_history_across_rounds() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-respond-history", || {
        let project = tmp.path().join("project");
        let (worker_id, task_id) = drive_to_request_changes_consensus("resp-hist", &project);

        // Round 1: agree p1, dispute p2.
        service::respond_review(
            "resp-hist",
            &task_id,
            &worker_id,
            &["p1".to_string()],
            &["p2".to_string()],
            Some("partial"),
            &project,
        )
        .unwrap();

        let state = service::session_status("resp-hist", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(
            task.review_history.len(),
            1,
            "one round of history recorded"
        );
        let history = &task.review_history[0];
        let p1 = history
            .points
            .iter()
            .find(|p| p.point_id == "p1")
            .expect("p1 preserved");
        assert_eq!(p1.state, ReviewPointState::Resolved, "p1 agreed → resolved");
        assert_eq!(p1.worker_note.as_deref(), Some("partial"));
        let p2 = history
            .points
            .iter()
            .find(|p| p.point_id == "p2")
            .expect("p2 preserved");
        assert_eq!(p2.state, ReviewPointState::Disputed, "p2 disputed");
        assert_eq!(p2.worker_note.as_deref(), Some("partial"));
    });
}

#[test]
fn respond_review_rejects_unknown_point_id() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-respond-unknown", || {
        let project = tmp.path().join("project");
        let (worker_id, task_id) = drive_to_request_changes_consensus("resp-unk", &project);

        let err = service::respond_review(
            "resp-unk",
            &task_id,
            &worker_id,
            &["p1".to_string()],
            &["p999".to_string()],
            None,
            &project,
        )
        .expect_err("unknown point id must be rejected");
        assert!(
            err.to_string().contains("p999"),
            "error should name the unknown point id, got: {err}"
        );
    });
}

#[test]
fn respond_review_rejects_duplicate_point_across_lists() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-respond-dup", || {
        let project = tmp.path().join("project");
        let (worker_id, task_id) = drive_to_request_changes_consensus("resp-dup", &project);

        let err = service::respond_review(
            "resp-dup",
            &task_id,
            &worker_id,
            &["p1".to_string()],
            &["p1".to_string(), "p2".to_string()],
            None,
            &project,
        )
        .expect_err("same point_id in agreed AND disputed must be rejected");
        assert!(
            err.to_string().contains("p1"),
            "error should name overlapping id, got: {err}"
        );
    });
}

#[test]
fn respond_review_rejects_partial_coverage() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-respond-partial", || {
        let project = tmp.path().join("project");
        let (worker_id, task_id) = drive_to_request_changes_consensus("resp-part", &project);

        // Consensus has p1 and p2 — worker must address both.
        let err = service::respond_review(
            "resp-part",
            &task_id,
            &worker_id,
            &["p1".to_string()],
            &[],
            None,
            &project,
        )
        .expect_err("partial coverage of consensus points must be rejected");
        assert!(
            err.to_string().contains("p2"),
            "error should cite the uncovered point id, got: {err}"
        );
    });
}

#[test]
fn respond_review_rejects_duplicate_within_single_list() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-respond-dup-agreed", || {
        let project = tmp.path().join("project");
        let (worker_id, task_id) = drive_to_request_changes_consensus("resp-dup-ag", &project);

        let err = service::respond_review(
            "resp-dup-ag",
            &task_id,
            &worker_id,
            &["p1".to_string(), "p1".to_string(), "p2".to_string()],
            &[],
            None,
            &project,
        )
        .expect_err("duplicate id inside agreed must be rejected");
        assert!(
            err.to_string().contains("p1"),
            "error should cite duplicate id, got: {err}"
        );
    });
}

#[test]
fn respond_review_rejects_non_submitter() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-respond-other", || {
        let project = tmp.path().join("project");
        let (_worker, task_id) = drive_to_request_changes_consensus("resp-rev-3", &project);
        // Leader agent id: derive from session state.
        let state = service::session_status("resp-rev-3", &project).unwrap();
        let leader_id = state.leader_id.as_ref().unwrap().clone();

        let result = service::respond_review(
            "resp-rev-3",
            &task_id,
            &leader_id,
            &["p1".to_string()],
            &[],
            None,
            &project,
        );
        assert!(result.is_err(), "non-submitter cannot respond");
    });
}
