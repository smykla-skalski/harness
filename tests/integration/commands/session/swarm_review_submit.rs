use harness::session::service;
use harness::session::types::{ReviewPoint, ReviewPointState, ReviewVerdict, TaskStatus};

use super::swarm_review_helpers::{
    join_reviewer, prepare_in_progress_task, setup_two_reviewers_on_claimed_task,
};
use super::with_session_test_env;

#[test]
fn submit_review_stamps_reviewer_entry_and_persists_review() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-submit-review-1", || {
        let project = tmp.path().join("project");
        let (_worker, task_id, gemini_id, _claude) =
            setup_two_reviewers_on_claimed_task("sub-rev-1", &project);

        service::submit_review(
            "sub-rev-1",
            &task_id,
            &gemini_id,
            ReviewVerdict::Approve,
            "LGTM",
            vec![],
            &project,
        )
        .expect("submit review");

        let state = service::session_status("sub-rev-1", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::InReview, "single submit stays in review");
        assert!(task.consensus.is_none(), "quorum not yet reached");
        let claim = task.review_claim.as_ref().unwrap();
        let entry = claim
            .reviewers
            .iter()
            .find(|r| r.reviewer_agent_id == gemini_id)
            .unwrap();
        assert!(entry.submitted_at.is_some(), "submitted_at stamped");
    });
}

#[test]
fn submit_review_quorum_approve_closes_task_as_done() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-submit-review-approve", || {
        let project = tmp.path().join("project");
        let (_worker, task_id, gemini_id, claude_id) =
            setup_two_reviewers_on_claimed_task("sub-rev-2", &project);

        service::submit_review(
            "sub-rev-2",
            &task_id,
            &gemini_id,
            ReviewVerdict::Approve,
            "ok",
            vec![],
            &project,
        )
        .unwrap();
        service::submit_review(
            "sub-rev-2",
            &task_id,
            &claude_id,
            ReviewVerdict::Approve,
            "ok",
            vec![],
            &project,
        )
        .unwrap();

        let state = service::session_status("sub-rev-2", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::Done);
        let consensus = task.consensus.as_ref().expect("consensus set");
        assert_eq!(consensus.verdict, ReviewVerdict::Approve);
        assert_eq!(consensus.reviewer_agent_ids.len(), 2);
        assert!(task.completed_at.is_some());
    });
}

#[test]
fn submit_review_quorum_request_changes_records_consensus_keeps_in_review() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-submit-review-changes", || {
        let project = tmp.path().join("project");
        let (_worker, task_id, gemini_id, claude_id) =
            setup_two_reviewers_on_claimed_task("sub-rev-3", &project);

        let points = vec![ReviewPoint {
            point_id: "p1".to_string(),
            text: "redo".to_string(),
            state: ReviewPointState::Open,
            worker_note: None,
        }];

        service::submit_review(
            "sub-rev-3",
            &task_id,
            &gemini_id,
            ReviewVerdict::RequestChanges,
            "rework",
            points,
            &project,
        )
        .unwrap();
        service::submit_review(
            "sub-rev-3",
            &task_id,
            &claude_id,
            ReviewVerdict::Approve,
            "lgtm",
            vec![],
            &project,
        )
        .unwrap();

        let state = service::session_status("sub-rev-3", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::InReview);
        let consensus = task.consensus.as_ref().expect("consensus set");
        assert_eq!(consensus.verdict, ReviewVerdict::RequestChanges);
        assert!(
            consensus.points.iter().any(|p| p.point_id == "p1"),
            "points aggregated"
        );
        assert!(task.completed_at.is_none());
    });
}

#[test]
fn submit_review_rejects_non_claimed_reviewer() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-submit-review-nonclaim", || {
        let project = tmp.path().join("project");
        let (_leader, worker_id, task_id) = prepare_in_progress_task("sub-rev-4", &project);
        service::submit_for_review("sub-rev-4", &task_id, &worker_id, None, &project).unwrap();
        let gemini_id = join_reviewer("sub-rev-4", "gemini", "GEMINI_SESSION_ID", &project);
        // No claim before submit.

        let result = service::submit_review(
            "sub-rev-4",
            &task_id,
            &gemini_id,
            ReviewVerdict::Approve,
            "",
            vec![],
            &project,
        );
        assert!(result.is_err(), "unclaimed reviewer cannot submit");
    });
}
