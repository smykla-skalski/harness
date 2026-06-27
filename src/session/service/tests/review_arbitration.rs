//! Review-loop termination guarantees (M3): the leader's arbitration path is
//! gated at the third round and, once reached, force-closes a deadlocked task.
//!
//! The consensus → `Done` happy path is covered by the daemon-level
//! `review_quorum` test; these tests pin the *other* exit of "the review loop
//! always closes" — the three-round dispute that hands off to the leader. They
//! set task state directly (as `review_guards` does) so the gate is exercised
//! without driving three full reviewer rounds.

use super::*;

const ARBITRATION_REASON: &str = crate::session::types::ARBITRATION_BLOCKED_REASON;

#[test]
fn arbitration_below_round_gate_is_rejected() {
    const SESSION: &str = "00000000-0000-4002-8000-0000000000a1";
    with_temp_project(|project| {
        let state = start_active_session("review", "", project, Some("claude"), Some(SESSION))
            .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let task = create_task(
            SESSION,
            "needs arbitration",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");

        let layout = storage::layout_from_project_dir(project, SESSION).expect("layout");
        storage::update_state(&layout, |state| {
            let task = state.tasks.get_mut(&task.task_id).expect("task");
            task.status = TaskStatus::Blocked;
            task.blocked_reason = Some(ARBITRATION_REASON.to_string());
            task.review_round = 2; // one round short of the gate
            Ok(())
        })
        .expect("set below gate");

        let result = arbitrate(
            SESSION,
            &task.task_id,
            &leader_id,
            crate::session::types::ReviewVerdict::Approve,
            "premature",
            project,
        );
        assert!(
            result.is_err(),
            "arbitration must be rejected before the third review round"
        );

        let after = session_status(SESSION, project).expect("status");
        assert_eq!(
            after.tasks.get(&task.task_id).expect("task").status,
            TaskStatus::Blocked,
            "a rejected arbitration must leave the task blocked"
        );
    });
}

#[test]
fn arbitration_at_round_gate_closes_task_to_done() {
    const SESSION: &str = "00000000-0000-4002-8000-0000000000a2";
    with_temp_project(|project| {
        let state = start_active_session("review", "", project, Some("claude"), Some(SESSION))
            .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let task = create_task(
            SESSION,
            "deadlocked review",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");

        let layout = storage::layout_from_project_dir(project, SESSION).expect("layout");
        storage::update_state(&layout, |state| {
            let task = state.tasks.get_mut(&task.task_id).expect("task");
            task.status = TaskStatus::Blocked;
            task.blocked_reason = Some(ARBITRATION_REASON.to_string());
            task.review_round = 3; // three rounds exhausted -> awaiting arbitration
            Ok(())
        })
        .expect("set at gate");

        arbitrate(
            SESSION,
            &task.task_id,
            &leader_id,
            crate::session::types::ReviewVerdict::Approve,
            "leader closes the deadlock",
            project,
        )
        .expect("leader arbitration should succeed at the round gate");

        let after = session_status(SESSION, project).expect("status");
        let task_after = after.tasks.get(&task.task_id).expect("task");
        assert_eq!(
            task_after.status,
            TaskStatus::Done,
            "leader arbitration with Approve must terminate the loop at Done"
        );
        assert!(
            task_after.completed_at.is_some(),
            "an arbitrated-approved task must record completion"
        );
        assert!(
            task_after.blocked_reason.is_none(),
            "arbitration must clear the blocked reason"
        );
    });
}

#[test]
fn non_leader_cannot_arbitrate() {
    const SESSION: &str = "00000000-0000-4002-8000-0000000000a3";
    with_temp_project(|project| {
        let state = start_active_session("review", "", project, Some("claude"), Some(SESSION))
            .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let worker = temp_env::with_vars([("CODEX_SESSION_ID", Some("arb-worker"))], || {
            join_session(
                SESSION,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker")
        });
        let worker_id = worker
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        let task = create_task(
            SESSION,
            "deadlocked review",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");

        let layout = storage::layout_from_project_dir(project, SESSION).expect("layout");
        storage::update_state(&layout, |state| {
            let task = state.tasks.get_mut(&task.task_id).expect("task");
            task.status = TaskStatus::Blocked;
            task.blocked_reason = Some(ARBITRATION_REASON.to_string());
            task.review_round = 3;
            Ok(())
        })
        .expect("set at gate");

        let result = arbitrate(
            SESSION,
            &task.task_id,
            &worker_id,
            crate::session::types::ReviewVerdict::Approve,
            "worker tries to self-resolve",
            project,
        );
        assert!(
            result.is_err(),
            "only the session leader may arbitrate a deadlocked task"
        );
        assert_eq!(
            session_status(SESSION, project)
                .expect("status")
                .tasks
                .get(&task.task_id)
                .expect("task")
                .status,
            TaskStatus::Blocked,
        );
    });
}
