use super::*;

const NOW: &str = "2026-07-15T10:00:00Z";
const TASK_ID: &str = "task-1";

fn managed_task_state() -> (SessionState, String) {
    let mut state = build_new_session("managed task", "test", "managed-run", "codex", None, NOW);
    let leader_id = apply_join_session(
        &mut state,
        "leader",
        "claude",
        SessionRole::Leader,
        &[],
        None,
        NOW,
        None,
        None,
    )
    .expect("join leader");
    let worker_id = apply_join_session(
        &mut state,
        "worker",
        "codex",
        SessionRole::Worker,
        &[],
        None,
        NOW,
        None,
        Some(crate::session::types::ManagedAgentRef::codex("run-1")),
    )
    .expect("join worker");
    apply_create_task_with_id(
        &mut state,
        TASK_ID,
        &TaskSpec {
            title: "managed work",
            context: None,
            severity: TaskSeverity::Medium,
            suggested_fix: None,
            source: TaskSource::Manual,
            observe_issue_id: None,
        },
        &leader_id,
        NOW,
    )
    .expect("create task");
    apply_assign_task(&mut state, TASK_ID, &worker_id, &leader_id, NOW).expect("assign task");
    apply_update_task_for_managed_run(
        &mut state,
        TASK_ID,
        TaskStatus::InProgress,
        None,
        &worker_id,
        NOW,
    )
    .expect("start task");
    (state, worker_id)
}

#[test]
fn managed_update_rejects_ended_and_allows_leaderless_degraded() {
    let (mut ended, ended_worker_id) = managed_task_state();
    ended.status = SessionStatus::Ended;

    let error = apply_update_task_for_managed_run(
        &mut ended,
        TASK_ID,
        TaskStatus::Blocked,
        Some("worker failed"),
        &ended_worker_id,
        NOW,
    )
    .expect_err("ended session must reject managed update");

    assert_eq!(error.code(), "KSRCLI090");
    assert_eq!(ended.tasks[TASK_ID].status, TaskStatus::InProgress);

    let (mut degraded, degraded_worker_id) = managed_task_state();
    degraded.status = SessionStatus::LeaderlessDegraded;
    degraded.leader_id = None;
    apply_update_task_for_managed_run(
        &mut degraded,
        TASK_ID,
        TaskStatus::Blocked,
        Some("worker failed"),
        &degraded_worker_id,
        NOW,
    )
    .expect("degraded session accepts managed update");

    assert_eq!(degraded.tasks[TASK_ID].status, TaskStatus::Blocked);
}

#[test]
fn managed_submit_rejects_ended_and_allows_leaderless_degraded() {
    let (mut ended, ended_worker_id) = managed_task_state();
    ended.status = SessionStatus::Ended;

    let error = apply_submit_for_review_for_managed_run(
        &mut ended,
        TASK_ID,
        &ended_worker_id,
        Some("ready"),
        NOW,
    )
    .expect_err("ended session must reject managed submit");

    assert_eq!(error.code(), "KSRCLI090");
    assert_eq!(ended.tasks[TASK_ID].status, TaskStatus::InProgress);
    assert_eq!(
        ended.tasks[TASK_ID].assigned_to.as_deref(),
        Some(ended_worker_id.as_str())
    );

    let (mut degraded, degraded_worker_id) = managed_task_state();
    degraded.status = SessionStatus::LeaderlessDegraded;
    degraded.leader_id = None;
    apply_submit_for_review_for_managed_run(
        &mut degraded,
        TASK_ID,
        &degraded_worker_id,
        Some("ready"),
        NOW,
    )
    .expect("degraded session accepts managed submit");

    assert_eq!(degraded.tasks[TASK_ID].status, TaskStatus::AwaitingReview);
    assert!(degraded.tasks[TASK_ID].assigned_to.is_none());
}
