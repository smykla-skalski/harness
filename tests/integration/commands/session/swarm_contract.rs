use clap::Parser;
use harness::app::cli::Cli;
use harness::session::service;
use harness::session::transport::{
    SessionCommand, SessionTaskCommand, SessionTransferLeaderArgs, TaskAssignArgs, TaskCreateArgs,
};
use harness::session::types::{SessionRole, TaskSeverity, TaskStatus};

use super::{session_cmd, with_session_test_env};
use crate::integration::helpers::run_command;

#[test]
fn leader_request_with_fallback_stays_non_leader_until_transfer() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_session_test_env(tmp.path(), "swarm-fallback", || {
        let project = tmp.path().join("project");
        let project_str = project.to_string_lossy().to_string();
        service::start_session_with_policy(
            "",
            "fallback transfer",
            &project,
            Some("swarm-fallback-1"),
            Some("swarm-default"),
        )
        .expect("start session");
        // Sessions start leaderless (status=AwaitingLeader). Join a leader
        // via the initial join path before exercising the join-conflict +
        // transfer behavior below.
        let joined_leader =
            temp_env::with_var("CLAUDE_SESSION_ID", Some("swarm-fallback-leader"), || {
                service::join_session(
                    "swarm-fallback-1",
                    SessionRole::Leader,
                    "claude",
                    &[],
                    Some("leader"),
                    &project,
                    None,
                )
                .expect("join leader")
            });
        let leader_id = joined_leader
            .leader_id
            .clone()
            .expect("leader id after join");

        temp_env::with_var("CODEX_SESSION_ID", Some("swarm-fallback-worker"), || {
            let cli = Cli::try_parse_from([
                "harness",
                "session",
                "join",
                "swarm-fallback-1",
                "--role",
                "leader",
                "--runtime",
                "codex",
                "--fallback-role",
                "improver",
                "--capabilities",
                "general",
                "--name",
                "fallback improver",
                "--project-dir",
                &project_str,
            ])
            .expect("parse join command");
            let exit_code = run_command(cli.command).expect("join via command");
            assert_eq!(exit_code, 0);
        });

        let joined = service::session_status("swarm-fallback-1", &project).expect("status");
        let improver = joined
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("improver join");
        assert_eq!(improver.role, SessionRole::Improver);
        assert_eq!(joined.leader_id.as_deref(), Some(leader_id.as_str()));

        let exit_code = run_command(session_cmd(SessionCommand::TransferLeader(
            SessionTransferLeaderArgs {
                session_id: "swarm-fallback-1".into(),
                new_leader_id: improver.agent_id.clone(),
                reason: Some("explicit takeover".into()),
                actor: leader_id,
                project_dir: Some(project_str),
            },
        )))
        .expect("transfer leader");
        assert_eq!(exit_code, 0);

        let updated = service::session_status("swarm-fallback-1", &project).expect("status");
        assert_eq!(
            updated.leader_id.as_deref(),
            Some(improver.agent_id.as_str())
        );
    });
}

#[test]
fn observer_creates_open_tasks_and_leader_assigns_worker() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_session_test_env(tmp.path(), "swarm-tasks", || {
        let project = tmp.path().join("project");
        let project_str = project.to_string_lossy().to_string();
        service::start_session_with_policy(
            "",
            "observer triage",
            &project,
            Some("swarm-tasks-1"),
            Some("swarm-default"),
        )
        .expect("start session");
        let joined_leader =
            temp_env::with_var("CLAUDE_SESSION_ID", Some("swarm-tasks-leader"), || {
                service::join_session(
                    "swarm-tasks-1",
                    SessionRole::Leader,
                    "claude",
                    &[],
                    Some("leader"),
                    &project,
                    None,
                )
                .expect("join leader")
            });
        let leader_id = joined_leader
            .leader_id
            .clone()
            .expect("leader id after join");

        let observer = temp_env::with_var("CODEX_SESSION_ID", Some("swarm-observer"), || {
            service::join_session(
                "swarm-tasks-1",
                SessionRole::Observer,
                "codex",
                &[],
                Some("Observer"),
                &project,
                None,
            )
            .expect("join observer")
        });
        let observer_id = observer
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("observer")
            .agent_id
            .clone();

        let worker = temp_env::with_var("CODEX_SESSION_ID", Some("swarm-worker"), || {
            service::join_session(
                "swarm-tasks-1",
                SessionRole::Worker,
                "gemini",
                &[],
                Some("Worker"),
                &project,
                None,
            )
            .expect("join worker")
        });
        let worker_id = worker
            .agents
            .values()
            .find(|agent| agent.runtime == "gemini")
            .expect("worker")
            .agent_id
            .clone();

        let exit_code = run_command(session_cmd(SessionCommand::Task {
            command: SessionTaskCommand::Create(TaskCreateArgs {
                session_id: "swarm-tasks-1".into(),
                title: "triage bridge regression".into(),
                context: Some("observer found a daemon control issue".into()),
                severity: TaskSeverity::High,
                suggested_fix: None,
                actor: observer_id,
                project_dir: Some(project_str.clone()),
            }),
        }))
        .expect("create task as observer");
        assert_eq!(exit_code, 0);

        let tasks = service::list_tasks("swarm-tasks-1", None, &project).expect("list tasks");
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].status, TaskStatus::Open);
        assert!(tasks[0].assigned_to.is_none());

        let exit_code = run_command(session_cmd(SessionCommand::Task {
            command: SessionTaskCommand::Assign(TaskAssignArgs {
                session_id: "swarm-tasks-1".into(),
                task_id: tasks[0].task_id.clone(),
                agent_id: worker_id.clone(),
                actor: leader_id,
                project_dir: Some(project_str),
            }),
        }))
        .expect("assign task as leader");
        assert_eq!(exit_code, 0);

        let updated = service::list_tasks("swarm-tasks-1", None, &project).expect("list tasks");
        assert_eq!(updated[0].status, TaskStatus::Open);
        assert_eq!(updated[0].assigned_to.as_deref(), Some(worker_id.as_str()));
    });
}
