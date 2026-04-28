//! Property-style sweep over the four-branch `apply_drop_task_on_agent` matrix.
//!
//! Variables: previous-assignee identity (none / different agent / same as target),
//! and target-worker busy state (free / locked on this same task / locked on a
//! different task). Post-condition is either `Started` (signal produced, target
//! locked on this task, queued_at None) or `Queued` (task queued, queued_at set,
//! target still locked on its prior task).

use super::*;

#[derive(Clone, Copy)]
enum PrevAssignee {
    None,
    OtherAgent,
    SameAsTarget,
}

#[derive(Clone, Copy)]
enum TargetBusyState {
    Free,
    LockedOnThisTask,
    LockedOnDifferentTask,
}

#[derive(Clone, Copy)]
enum ExpectedOutcome {
    Started,
    Queued,
}

fn run_case(prev: PrevAssignee, target: TargetBusyState, expected: ExpectedOutcome) {
    with_temp_project(|project| {
        let session_id = "drop-prop";
        let leader_state =
            start_active_session("test", "", project, Some("claude"), Some(session_id))
                .expect("start");
        let leader_id = leader_state.leader_id.clone().expect("leader id");

        let target_join = temp_env::with_vars([("CODEX_SESSION_ID", Some("prop-target"))], || {
            join_session(
                session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join target")
        });
        let target_id = target_join
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("target id")
            .clone();

        let other_id = match prev {
            PrevAssignee::OtherAgent => {
                let other_join =
                    temp_env::with_vars([("CODEX_SESSION_ID", Some("prop-other"))], || {
                        join_session(
                            session_id,
                            SessionRole::Worker,
                            "codex",
                            &[],
                            None,
                            project,
                            None,
                        )
                        .expect("join other")
                    });
                other_join
                    .agents
                    .keys()
                    .find(|id| id.starts_with("codex-") && *id != &target_id)
                    .cloned()
            }
            _ => None,
        };

        let primary = create_task(
            session_id,
            "primary",
            Some("primary task under test"),
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("primary");

        let setup_target = match (prev, target) {
            (PrevAssignee::None, TargetBusyState::Free) => None,
            (PrevAssignee::None, TargetBusyState::LockedOnThisTask) => unreachable!(
                "with prev=None the task is unassigned, so target cannot be locked on it"
            ),
            (PrevAssignee::None, TargetBusyState::LockedOnDifferentTask) => {
                let other_task = create_task(
                    session_id,
                    "filler",
                    None,
                    TaskSeverity::Low,
                    &leader_id,
                    project,
                )
                .expect("filler");
                assign_task(
                    session_id,
                    &other_task.task_id,
                    &target_id,
                    &leader_id,
                    project,
                )
                .expect("assign filler");
                Some(other_task.task_id)
            }
            (PrevAssignee::OtherAgent, _) => {
                let other = other_id.as_deref().expect("other agent id");
                assign_task(session_id, &primary.task_id, other, &leader_id, project)
                    .expect("assign primary to other");
                match target {
                    TargetBusyState::Free => None,
                    TargetBusyState::LockedOnThisTask => unreachable!(
                        "primary is locked on `other`, so target cannot also hold this same task"
                    ),
                    TargetBusyState::LockedOnDifferentTask => {
                        let other_task = create_task(
                            session_id,
                            "filler",
                            None,
                            TaskSeverity::Low,
                            &leader_id,
                            project,
                        )
                        .expect("filler");
                        assign_task(
                            session_id,
                            &other_task.task_id,
                            &target_id,
                            &leader_id,
                            project,
                        )
                        .expect("assign filler");
                        Some(other_task.task_id)
                    }
                }
            }
            (PrevAssignee::SameAsTarget, TargetBusyState::Free) => {
                unreachable!("with prev=SameAsTarget the target holds the task, so it is not Free")
            }
            (PrevAssignee::SameAsTarget, TargetBusyState::LockedOnThisTask) => {
                assign_task(
                    session_id,
                    &primary.task_id,
                    &target_id,
                    &leader_id,
                    project,
                )
                .expect("assign primary to target");
                None
            }
            (PrevAssignee::SameAsTarget, TargetBusyState::LockedOnDifferentTask) => {
                // Target is locked on a different task, but the primary task is
                // still assigned to target as well. Set up by assigning primary
                // first (locks target), then create + assign a different task to
                // target — but the second assign would re-lock onto the second
                // task. This branch is not realistically constructible: the
                // session model permits only one current_task_id per agent at
                // a time, so SameAsTarget is mutually exclusive with
                // LockedOnDifferentTask. Skip via early return — covered by
                // SameAsTarget+LockedOnThisTask above.
                return;
            }
        };

        drop_task(
            session_id,
            &primary.task_id,
            &protocol::TaskDropTarget::Agent {
                agent_id: target_id.clone(),
            },
            TaskQueuePolicy::Locked,
            &leader_id,
            project,
        )
        .expect("drop primary");

        let state = session_status(session_id, project).expect("status");
        let primary_after = state.tasks.get(&primary.task_id).expect("primary task");
        let target_agent = state.agents.get(&target_id).expect("target agent");

        match expected {
            ExpectedOutcome::Started => {
                assert!(
                    primary_after.queued_at.is_none(),
                    "Started branch: queued_at must be None"
                );
                assert_eq!(
                    primary_after.assigned_to.as_deref(),
                    Some(target_id.as_str()),
                    "Started branch: task assigned to target"
                );
                assert_eq!(
                    target_agent.current_task_id.as_deref(),
                    Some(primary.task_id.as_str()),
                    "Started branch: target locked on this task"
                );
                let signals = list_signals(session_id, Some(&target_id), project).expect("signals");
                assert!(
                    signals
                        .iter()
                        .any(|record| record.signal.command == START_TASK_SIGNAL_COMMAND
                            && record.signal.payload.action_hint.as_deref()
                                == Some(task_start_action_hint(&primary.task_id).as_str())),
                    "Started branch: a task-start signal must be produced for the primary task"
                );
            }
            ExpectedOutcome::Queued => {
                assert!(
                    primary_after.queued_at.is_some(),
                    "Queued branch: queued_at must be set"
                );
                assert_eq!(
                    primary_after.assigned_to.as_deref(),
                    Some(target_id.as_str()),
                    "Queued branch: task assigned to target"
                );
                let prior_lock = setup_target.as_deref();
                assert_eq!(
                    target_agent.current_task_id.as_deref(),
                    prior_lock,
                    "Queued branch: target's lock is unchanged from the prior task it was holding"
                );
            }
        }
    });
}

#[test]
fn drop_prev_none_target_free_starts() {
    run_case(
        PrevAssignee::None,
        TargetBusyState::Free,
        ExpectedOutcome::Started,
    );
}

#[test]
fn drop_prev_none_target_locked_on_other_queues() {
    run_case(
        PrevAssignee::None,
        TargetBusyState::LockedOnDifferentTask,
        ExpectedOutcome::Queued,
    );
}

#[test]
fn drop_prev_other_target_free_starts() {
    run_case(
        PrevAssignee::OtherAgent,
        TargetBusyState::Free,
        ExpectedOutcome::Started,
    );
}

#[test]
fn drop_prev_other_target_locked_on_other_queues() {
    run_case(
        PrevAssignee::OtherAgent,
        TargetBusyState::LockedOnDifferentTask,
        ExpectedOutcome::Queued,
    );
}

#[test]
fn drop_prev_same_target_locked_on_this_starts() {
    run_case(
        PrevAssignee::SameAsTarget,
        TargetBusyState::LockedOnThisTask,
        ExpectedOutcome::Started,
    );
}
