use harness::app::cli::Command;
use harness::session::service;
use harness::session::transport::{SessionCommand, SessionTaskCommand, TaskListArgs};
use harness::session::types::{SessionRole, SessionStatus, TaskSeverity, TaskStatus};

use super::super::helpers::*;

fn session_cmd(command: SessionCommand) -> Command {
    Command::Session { command }
}

#[test]
fn session_lifecycle_start_join_task_end() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("integ-lifecycle")),
        ],
        || {
            let project = tmp.path().join("project");

            let state = service::start_session(
                "integration test",
                &project,
                Some("claude"),
                Some("lifecycle-1"),
            )
            .unwrap();
            assert_eq!(state.status, SessionStatus::Active);
            assert_eq!(state.agents.len(), 1);

            let leader_id = state.leader_id.unwrap();

            let state = service::join_session(
                "lifecycle-1",
                SessionRole::Worker,
                "codex",
                &["general".into()],
                None,
                &project,
            )
            .unwrap();
            assert_eq!(state.agents.len(), 2);

            let worker_id = state
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .unwrap()
                .clone();

            let task = service::create_task(
                "lifecycle-1",
                "fix integration bug",
                Some("test context"),
                TaskSeverity::High,
                &leader_id,
                &project,
            )
            .unwrap();
            assert_eq!(task.status, TaskStatus::Open);

            service::assign_task(
                "lifecycle-1",
                &task.task_id,
                &worker_id,
                &leader_id,
                &project,
            )
            .unwrap();

            service::update_task(
                "lifecycle-1",
                &task.task_id,
                TaskStatus::Done,
                Some("completed"),
                &worker_id,
                &project,
            )
            .unwrap();

            service::end_session("lifecycle-1", &leader_id, &project).unwrap();

            let state = service::session_status("lifecycle-1", &project).unwrap();
            assert_eq!(state.status, SessionStatus::Ended);
        },
    );
}

#[test]
fn session_task_list_via_cli_command() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("integ-task-list")),
        ],
        || {
            let project = tmp.path().join("project");
            let project_str = project.to_string_lossy().to_string();

            let state = service::start_session(
                "task list test",
                &project,
                Some("claude"),
                Some("tasklist-1"),
            )
            .unwrap();
            let leader_id = state.leader_id.unwrap();

            service::create_task(
                "tasklist-1",
                "task alpha",
                None,
                TaskSeverity::Low,
                &leader_id,
                &project,
            )
            .unwrap();
            service::create_task(
                "tasklist-1",
                "task beta",
                None,
                TaskSeverity::Critical,
                &leader_id,
                &project,
            )
            .unwrap();

            let cmd = session_cmd(SessionCommand::Task {
                command: SessionTaskCommand::List(TaskListArgs {
                    session_id: "tasklist-1".into(),
                    status: None,
                    json: true,
                    project_dir: Some(project_str),
                }),
            });
            let result = run_command(cmd);
            assert!(result.is_ok());
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
fn session_list_shows_active_sessions() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("integ-list")),
        ],
        || {
            let project = tmp.path().join("project");

            service::start_session("goal one", &project, Some("claude"), Some("list-a")).unwrap();
            service::start_session("goal two", &project, Some("codex"), Some("list-b")).unwrap();

            let sessions = service::list_sessions(&project).unwrap();
            assert_eq!(sessions.len(), 2);
        },
    );
}

#[test]
fn cannot_end_session_with_active_tasks() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("integ-active")),
        ],
        || {
            let project = tmp.path().join("project");

            let state = service::start_session(
                "active task test",
                &project,
                Some("claude"),
                Some("active-1"),
            )
            .unwrap();
            let leader_id = state.leader_id.unwrap();

            let joined = service::join_session(
                "active-1",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                &project,
            )
            .unwrap();
            let worker_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .unwrap()
                .clone();

            let task = service::create_task(
                "active-1",
                "in progress work",
                None,
                TaskSeverity::Medium,
                &leader_id,
                &project,
            )
            .unwrap();
            service::assign_task(
                "active-1",
                &task.task_id,
                &worker_id,
                &leader_id,
                &project,
            )
            .unwrap();

            let result = service::end_session("active-1", &leader_id, &project);
            assert!(result.is_err());
            let err = result.unwrap_err();
            assert_eq!(err.code(), "KSRCLI092");
        },
    );
}

#[test]
fn concurrent_task_creation_from_multiple_agents() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("integ-concurrent")),
        ],
        || {
            let project = tmp.path().join("project");
            let state = service::start_session(
                "concurrency test",
                &project,
                Some("claude"),
                Some("conc-1"),
            )
            .unwrap();
            let leader_id = state.leader_id.unwrap();

            let joined1 = service::join_session(
                "conc-1",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                &project,
            )
            .unwrap();
            let worker1 = joined1
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .unwrap()
                .clone();

            let joined2 = service::join_session(
                "conc-1",
                SessionRole::Reviewer,
                "gemini",
                &[],
                None,
                &project,
            )
            .unwrap();
            let reviewer = joined2
                .agents
                .keys()
                .find(|id| id.starts_with("gemini"))
                .unwrap()
                .clone();

            // Both agents create tasks concurrently (sequential here but
            // exercises the same lock path)
            service::create_task(
                "conc-1",
                "worker task",
                None,
                TaskSeverity::High,
                &worker1,
                &project,
            )
            .unwrap();
            service::create_task(
                "conc-1",
                "reviewer task",
                None,
                TaskSeverity::Medium,
                &reviewer,
                &project,
            )
            .unwrap();

            let tasks = service::list_tasks("conc-1", None, &project).unwrap();
            assert_eq!(tasks.len(), 2);
            // Sorted by severity desc: High first
            assert_eq!(tasks[0].severity, TaskSeverity::High);
            assert_eq!(tasks[1].severity, TaskSeverity::Medium);

            // Assign and update from different agents
            service::assign_task("conc-1", &tasks[0].task_id, &worker1, &leader_id, &project)
                .unwrap();
            service::update_task(
                "conc-1",
                &tasks[0].task_id,
                TaskStatus::Done,
                Some("done by worker"),
                &worker1,
                &project,
            )
            .unwrap();

            // Leader can end now (only 1 task in progress was just completed)
            service::end_session("conc-1", &leader_id, &project).unwrap();
            let final_state = service::session_status("conc-1", &project).unwrap();
            assert_eq!(final_state.status, SessionStatus::Ended);
        },
    );
}

#[test]
fn multi_agent_observation_merges_issues() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("integ-observe")),
        ],
        || {
            let project = tmp.path().join("project");
            let state = service::start_session(
                "observe test",
                &project,
                Some("claude"),
                Some("obs-1"),
            )
            .unwrap();
            let _leader_id = state.leader_id.unwrap();

            service::join_session(
                "obs-1",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                &project,
            )
            .unwrap();

            // The observe command will try to find agent logs via runtime
            // adapters. With no actual logs, it should return 0 issues.
            let result = harness::session::observe::execute_session_observe(
                "obs-1",
                &project,
                true,
            );
            assert!(result.is_ok());
            // Exit code 0 means no issues found (no logs to scan)
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
fn transfer_leader_and_role_reassignment() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("integ-transfer")),
        ],
        || {
            let project = tmp.path().join("project");
            let state = service::start_session(
                "transfer test",
                &project,
                Some("claude"),
                Some("xfer-1"),
            )
            .unwrap();
            let leader_id = state.leader_id.unwrap();

            let joined = service::join_session(
                "xfer-1",
                SessionRole::Observer,
                "codex",
                &[],
                None,
                &project,
            )
            .unwrap();
            let observer_id = joined
                .agents
                .keys()
                .find(|id| id.starts_with("codex"))
                .unwrap()
                .clone();

            // Observer initiates transfer
            service::transfer_leader(
                "xfer-1",
                &observer_id,
                Some("leader unresponsive"),
                &observer_id,
                &project,
            )
            .unwrap();

            let state = service::session_status("xfer-1", &project).unwrap();
            assert_eq!(state.leader_id.as_deref(), Some(observer_id.as_str()));

            // Old leader is now Worker
            let old_leader = state.agents.get(&leader_id).unwrap();
            assert_eq!(old_leader.role, SessionRole::Worker);

            // New leader is now Leader
            let new_leader = state.agents.get(&observer_id).unwrap();
            assert_eq!(new_leader.role, SessionRole::Leader);
        },
    );
}
