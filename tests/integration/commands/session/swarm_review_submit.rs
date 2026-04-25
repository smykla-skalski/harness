use harness::session::service;
use harness::session::types::{
    AgentStatus, ReviewPoint, ReviewPointState, ReviewVerdict, TaskStatus,
};

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
        assert_eq!(
            task.status,
            TaskStatus::InReview,
            "single submit stays in review"
        );
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
fn quorum_approve_releases_submitter_and_allows_new_assignment() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-approve-release", || {
        let project = tmp.path().join("project");
        let (worker_id, task_id, gemini_id, claude_id) =
            setup_two_reviewers_on_claimed_task("approve-rel", &project);
        service::submit_review(
            "approve-rel",
            &task_id,
            &gemini_id,
            ReviewVerdict::Approve,
            "ok",
            vec![],
            &project,
        )
        .unwrap();
        service::submit_review(
            "approve-rel",
            &task_id,
            &claude_id,
            ReviewVerdict::Approve,
            "ok",
            vec![],
            &project,
        )
        .unwrap();

        let state = service::session_status("approve-rel", &project).unwrap();
        let agent = state.agents.get(&worker_id).expect("submitter present");
        assert_eq!(
            agent.status,
            AgentStatus::Idle,
            "worker must be assignable again after approve"
        );
        assert!(
            agent.current_task_id.is_none(),
            "completed task must not stay pinned"
        );

        // Second task assignable to the same worker.
        let leader_id = state
            .agents
            .values()
            .find(|agent| agent.role == harness::session::types::SessionRole::Leader)
            .unwrap()
            .agent_id
            .clone();
        let second = service::create_task(
            "approve-rel",
            "followup",
            None,
            harness::session::types::TaskSeverity::Low,
            &leader_id,
            &project,
        )
        .unwrap();
        service::assign_task(
            "approve-rel",
            &second.task_id,
            &worker_id,
            &leader_id,
            &project,
        )
        .expect("worker assignable after approve");
    });
}

#[test]
fn quorum_ignores_stale_reviews_from_prior_rounds() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-stale-rounds", || {
        let project = tmp.path().join("project");
        let (worker_id, task_id, gemini_id, claude_id) =
            setup_two_reviewers_on_claimed_task("stale-rnd", &project);
        // Round 1: gemini RequestChanges with one open point, claude Approve.
        let points = vec![ReviewPoint {
            point_id: "p1".to_string(),
            text: "redo".to_string(),
            state: ReviewPointState::Open,
            worker_note: None,
        }];
        service::submit_review(
            "stale-rnd",
            &task_id,
            &gemini_id,
            ReviewVerdict::RequestChanges,
            "redo",
            points,
            &project,
        )
        .unwrap();
        service::submit_review(
            "stale-rnd",
            &task_id,
            &claude_id,
            ReviewVerdict::Approve,
            "ok",
            vec![],
            &project,
        )
        .unwrap();

        // Worker disputes p1 which clears submitted_at and bumps round.
        service::respond_review(
            "stale-rnd",
            &task_id,
            &worker_id,
            &[],
            &["p1".to_string()],
            Some("disagree"),
            &project,
        )
        .unwrap();

        // Round 2: both reviewers approve. Task must close as Done despite
        // the stale round-1 RequestChanges review still sitting on disk.
        service::submit_review(
            "stale-rnd",
            &task_id,
            &gemini_id,
            ReviewVerdict::Approve,
            "now ok",
            vec![],
            &project,
        )
        .unwrap();
        service::submit_review(
            "stale-rnd",
            &task_id,
            &claude_id,
            ReviewVerdict::Approve,
            "still ok",
            vec![],
            &project,
        )
        .unwrap();

        let state = service::session_status("stale-rnd", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(
            task.status,
            TaskStatus::Done,
            "round 2 approve must close task regardless of stale round 1 reviews"
        );
        let consensus = task.consensus.as_ref().expect("consensus set");
        assert_eq!(consensus.verdict, ReviewVerdict::Approve);
    });
}

#[test]
fn rejected_submit_review_leaves_no_durable_record() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-no-record-on-reject", || {
        let project = tmp.path().join("project");
        let (_leader, worker_id, task_id) = prepare_in_progress_task("nr-reject", &project);
        service::submit_for_review("nr-reject", &task_id, &worker_id, None, &project).unwrap();
        let gemini_id = join_reviewer("nr-reject", "gemini", "GEMINI_SESSION_ID", &project);
        // Skip claim: submit_review must reject AND must not touch reviews.jsonl.

        let err = service::submit_review(
            "nr-reject",
            &task_id,
            &gemini_id,
            ReviewVerdict::Approve,
            "sneaky",
            vec![],
            &project,
        )
        .expect_err("unclaimed reviewer cannot submit");
        drop(err);

        let reviews_path = project
            .join("agents")
            .join("sessions")
            .join("nr-reject")
            .join("tasks")
            .join(&task_id)
            .join("reviews.jsonl");
        assert!(
            !reviews_path.exists() || std::fs::read_to_string(&reviews_path).unwrap().is_empty(),
            "rejected submit_review must leave no durable review record at {reviews_path:?}"
        );
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
