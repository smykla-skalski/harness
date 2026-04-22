use super::*;

#[test]
fn create_task_db_direct_bootstraps_file_backed_session() {
    with_temp_project(|project| {
        let state = start_active_file_session(
            "bootstrapped db-direct task",
            "",
            project,
            Some("claude"),
            Some("bootstrapped-db-direct"),
        )
        .expect("start session");
        let leader_id = state.leader_id.expect("leader id");
        let db = setup_db_with_project(project);

        let detail = create_task(
            &state.session_id,
            &TaskCreateRequest {
                actor: leader_id,
                title: "db-bootstrap task".into(),
                context: None,
                severity: crate::session::types::TaskSeverity::Medium,
                suggested_fix: None,
            },
            Some(&db),
        )
        .expect("create task via db bootstrap");

        assert_eq!(detail.tasks.len(), 1);
        assert_eq!(detail.tasks[0].title, "db-bootstrap task");

        let db_state = db
            .load_session_state(&state.session_id)
            .expect("load state")
            .expect("state present");
        assert_eq!(db_state.tasks.len(), 1);
        assert_eq!(
            db_state.tasks.values().next().expect("task present").title,
            "db-bootstrap task"
        );
    });
}
