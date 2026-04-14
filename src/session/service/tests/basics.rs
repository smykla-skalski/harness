use super::*;

#[test]
fn start_creates_session_with_leader() {
    with_temp_project(|project| {
        let state =
            start_session("test goal", "", project, Some("claude"), None).expect("start");
        assert_eq!(state.status, SessionStatus::Active);
        assert_eq!(state.agents.len(), 1);
        assert_eq!(state.metrics.agent_count, 1);
        let leader = state.agents.values().next().expect("leader");
        assert_eq!(leader.role, SessionRole::Leader);
        assert_eq!(leader.runtime, "claude");
        assert_eq!(leader.agent_session_id.as_deref(), Some("test-service"));
        assert_eq!(leader.runtime_capabilities.runtime, "claude");
        assert!(leader.last_activity_at.is_some());
    });
}

#[test]
fn join_adds_agent() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("s1")).expect("start");
        let state = join_session(
            &state.session_id,
            SessionRole::Worker,
            "codex",
            &["general".into()],
            None,
            project,
            None,
        )
        .expect("join");
        assert_eq!(state.agents.len(), 2);
        assert_eq!(state.metrics.agent_count, 2);
    });
}

#[test]
fn start_session_rejects_duplicate_session_id() {
    with_temp_project(|project| {
        start_session("goal1", "", project, Some("claude"), Some("dup")).expect("first");
        let error =
            start_session("goal2", "", project, Some("codex"), Some("dup")).expect_err("dup");

        assert_eq!(error.code(), "KSRCLI092");
        assert_eq!(
            session_status("dup", project).expect("status").context,
            "goal1"
        );
    });
}

#[test]
fn start_session_rejects_unsafe_session_id() {
    with_temp_project(|project| {
        let tmp_root = project.parent().expect("parent");
        let escape_dir = tmp_root.join("unsafe-session");
        let unsafe_id = escape_dir.to_string_lossy().into_owned();

        let error = start_session("goal", "", project, Some("claude"), Some(&unsafe_id))
            .expect_err("id");

        assert_eq!(error.code(), "KSRCLI059");
        assert!(!escape_dir.join("state.json").exists());
    });
}

#[test]
fn start_session_requires_known_runtime() {
    with_temp_project(|project| {
        let missing_runtime = start_session("goal", "", project, None, Some("no-runtime"))
            .expect_err("runtime is required");
        assert_eq!(missing_runtime.code(), "KSRCLI092");

        let unknown_runtime = start_session("goal", "", project, Some("unknown"), Some("bad"))
            .expect_err("unknown runtime should be rejected");
        assert_eq!(unknown_runtime.code(), "KSRCLI092");
    });
}

#[test]
fn start_session_accepts_vibe_and_opencode_as_distinct_runtime_names() {
    with_temp_project(|project| {
        let vibe = start_session("goal", "", project, Some("vibe"), Some("vibe-runtime"))
            .expect("vibe runtime should be accepted");
        let opencode = start_session(
            "goal",
            "",
            project,
            Some("opencode"),
            Some("opencode-runtime"),
        )
        .expect("opencode runtime should remain accepted");

        let vibe_leader = vibe
            .agents
            .values()
            .find(|agent| agent.role == SessionRole::Leader)
            .expect("vibe leader");
        assert_eq!(vibe_leader.runtime, "vibe");
        assert_eq!(vibe_leader.runtime_capabilities.runtime, "vibe");

        let opencode_leader = opencode
            .agents
            .values()
            .find(|agent| agent.role == SessionRole::Leader)
            .expect("opencode leader");
        assert_eq!(opencode_leader.runtime, "opencode");
        assert_eq!(opencode_leader.runtime_capabilities.runtime, "opencode");
    });
}

#[test]
fn auto_generated_session_ids_are_unique() {
    with_temp_project(|project| {
        let first = start_session("goal1", "", project, Some("claude"), None).expect("first");
        let second = start_session("goal2", "", project, Some("codex"), None).expect("second");
        assert_ne!(first.session_id, second.session_id);
    });
}

#[test]
fn join_same_runtime_keeps_distinct_agents() {
    with_temp_project(|project| {
        start_session("test", "", project, Some("claude"), Some("join-unique")).expect("start");

        let (first, second) =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("codex-worker"))], || {
                let first = join_session(
                    "join-unique",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("first");
                let second = join_session(
                    "join-unique",
                    SessionRole::Reviewer,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("second");
                (first, second)
            });

        assert_eq!(first.agents.len(), 2);
        assert_eq!(second.agents.len(), 3);
        let codex_ids: Vec<_> = second
            .agents
            .keys()
            .filter(|id| id.starts_with("codex-"))
            .collect();
        assert_eq!(codex_ids.len(), 2);
    });
}

#[test]
fn join_records_runtime_session_id_when_available() {
    with_temp_project(|project| {
        start_session("test", "", project, Some("claude"), Some("join-runtime")).unwrap();

        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("codex-worker"))], || {
            join_session(
                "join-runtime",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .unwrap()
        });

        let codex_worker = joined
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("codex worker should be present");
        assert_eq!(
            codex_worker.agent_session_id.as_deref(),
            Some("codex-worker")
        );
    });
}

#[test]
fn end_session_requires_leader() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("s2")).expect("start");
        let joined = join_session(
            &state.session_id,
            SessionRole::Worker,
            "codex",
            &[],
            None,
            project,
            None,
        )
        .expect("join");
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex"))
            .expect("worker id")
            .clone();
        let result = end_session(&state.session_id, &worker_id, project);
        assert!(result.is_err());
    });
}

#[test]
fn task_lifecycle() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("s3")).expect("start");
        let leader_id = state.leader_id.expect("leader id");

        let item = create_task(
            "s3",
            "fix bug",
            Some("details"),
            TaskSeverity::High,
            &leader_id,
            project,
        )
        .expect("task");
        assert_eq!(item.status, TaskStatus::Open);

        let tasks = list_tasks("s3", None, project).expect("list");
        assert_eq!(tasks.len(), 1);

        update_task(
            "s3",
            &item.task_id,
            TaskStatus::Done,
            Some("fixed"),
            &leader_id,
            project,
        )
        .expect("update");

        let tasks = list_tasks("s3", Some(TaskStatus::Done), project).expect("done");
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].notes.len(), 1);
        assert!(tasks[0].completed_at.is_some());
    });
}
