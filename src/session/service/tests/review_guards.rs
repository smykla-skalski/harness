use super::*;

#[test]
fn arbitration_blocked_task_rejects_generic_mutation_paths() {
    with_temp_project(|project| {
        let state = start_active_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("arbitration-block-guards"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("blocked-worker"))], || {
            join_session(
                "arbitration-block-guards",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join")
        });
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        let task = create_task(
            "arbitration-block-guards",
            "blocked",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");
        let layout =
            storage::layout_from_project_dir(project, "arbitration-block-guards").expect("layout");
        storage::update_state(&layout, |state| {
            let task = state.tasks.get_mut(&task.task_id).expect("task");
            task.status = TaskStatus::Blocked;
            task.blocked_reason =
                Some(crate::session::types::ARBITRATION_BLOCKED_REASON.to_string());
            Ok(())
        })
        .expect("block for arbitration");

        let update = update_task(
            "arbitration-block-guards",
            &task.task_id,
            TaskStatus::Open,
            None,
            &leader_id,
            project,
        )
        .expect_err("generic update blocked");
        assert!(update.to_string().contains("arbitrate"));

        let assign = assign_task(
            "arbitration-block-guards",
            &task.task_id,
            &worker_id,
            &leader_id,
            project,
        )
        .expect_err("assign blocked");
        assert!(assign.to_string().contains("arbitrate"));

        let drop = drop_task(
            "arbitration-block-guards",
            &task.task_id,
            &protocol::TaskDropTarget::Agent {
                agent_id: worker_id.clone(),
            },
            TaskQueuePolicy::Locked,
            &leader_id,
            project,
        )
        .expect_err("drop blocked");
        assert!(drop.to_string().contains("arbitrate"));

        let checkpoint = record_task_checkpoint(
            "arbitration-block-guards",
            &task.task_id,
            &leader_id,
            "progress",
            10,
            project,
        )
        .expect_err("checkpoint blocked");
        assert!(checkpoint.to_string().contains("arbitrate"));
    });
}
