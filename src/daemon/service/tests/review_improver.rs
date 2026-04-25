use crate::daemon::protocol::{
    ImproverApplyRequest, TaskAssignRequest, TaskCreateRequest, TaskSubmitForReviewRequest,
    TaskUpdateRequest,
};
use crate::session::types::{SessionRole, TaskStatus};

use super::*;

#[test]
fn improver_apply_async_resolves_session_via_async_db_for_dry_run() {
    with_temp_project(|project| {
        std::fs::create_dir_all(project.join("agents/skills")).expect("skills dir");
        std::fs::write(project.join("agents/skills/SKILL.md"), "before\n").expect("skill");
        let runtime_tokio = tokio::runtime::Runtime::new().expect("runtime");
        runtime_tokio.block_on(async {
            let db_path = project
                .parent()
                .expect("project parent")
                .join("daemon-improver-async.sqlite");
            let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                .await
                .expect("open async daemon db");

            let state = start_direct_session_async(
                &async_db,
                project,
                "daemon-improver-async",
                "async improver apply",
                "async flow",
                None,
            )
            .await;
            let leader_id = state.leader_id.clone().expect("leader id");
            let improver_id =
                temp_env::async_with_vars([("CODEX_SESSION_ID", Some("async-improver"))], async {
                    let joined = join_session_direct_async(
                        &state.session_id,
                        &crate::daemon::protocol::SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Improver,
                            fallback_role: None,
                            capabilities: vec![],
                            name: Some("Improver".into()),
                            project_dir: project.to_string_lossy().into(),
                            persona: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("join improver");
                    joined
                        .agents
                        .values()
                        .find(|agent| agent.role == SessionRole::Improver)
                        .expect("improver")
                        .agent_id
                        .clone()
                })
                .await;

            let outcome = crate::daemon::service::improver_apply_async(
                &state.session_id,
                &ImproverApplyRequest {
                    actor: improver_id,
                    issue_id: "async-issue".into(),
                    target: crate::session::service::ImproverTarget::Skill,
                    rel_path: "SKILL.md".into(),
                    new_contents: "after\n".into(),
                    project_dir: project.to_string_lossy().into_owned(),
                    dry_run: true,
                },
                &async_db,
            )
            .await
            .expect("async dry-run resolves via async db");
            assert!(!outcome.applied, "dry-run must not modify disk");
            assert_ne!(outcome.before_sha256, outcome.after_sha256);
            assert_eq!(
                std::fs::read_to_string(project.join("agents/skills/SKILL.md")).unwrap(),
                "before\n",
                "skill file unchanged on dry-run"
            );

            let _ = leader_id;
        });
    });
}

#[test]
fn improver_apply_rejects_worker_and_uses_session_project_dir_for_dry_run() {
    with_temp_project(|project| {
        std::fs::create_dir_all(project.join("agents/skills")).expect("skills dir");
        std::fs::write(project.join("agents/skills/SKILL.md"), "old\n").expect("skill");
        let state = start_active_file_session(
            "improver auth",
            "",
            project,
            Some("claude"),
            Some("daemon-improver-auth"),
        )
        .expect("start session");
        let worker_joined = temp_env::with_var("CODEX_SESSION_ID", Some("improver-worker"), || {
            session_service::join_session(
                "daemon-improver-auth",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker")
        });
        let worker_id = worker_joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        let improver_joined =
            temp_env::with_var("CODEX_SESSION_ID", Some("improver-agent"), || {
                session_service::join_session(
                    "daemon-improver-auth",
                    SessionRole::Improver,
                    "codex",
                    &[],
                    Some("Improver"),
                    project,
                    None,
                )
                .expect("join improver")
            });
        let improver_id = improver_joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-") && *id != &worker_id)
            .expect("improver id")
            .clone();
        let bogus = tempfile::tempdir().expect("bogus project");

        let denied = improver_apply(
            &state.session_id,
            &ImproverApplyRequest {
                actor: worker_id,
                issue_id: "issue-1".into(),
                target: crate::session::service::ImproverTarget::Skill,
                rel_path: "SKILL.md".into(),
                new_contents: "new\n".into(),
                project_dir: bogus.path().to_string_lossy().into_owned(),
                dry_run: true,
            },
            None,
        )
        .expect_err("worker cannot apply");
        assert_eq!(denied.code(), "KSRCLI091");

        let outcome = improver_apply(
            &state.session_id,
            &ImproverApplyRequest {
                actor: improver_id,
                issue_id: "issue-2".into(),
                target: crate::session::service::ImproverTarget::Skill,
                rel_path: "SKILL.md".into(),
                new_contents: "new\n".into(),
                project_dir: bogus.path().to_string_lossy().into_owned(),
                dry_run: true,
            },
            None,
        )
        .expect("dry run uses session project");
        assert!(!outcome.applied);
        assert_eq!(
            std::fs::read_to_string(project.join("agents/skills/SKILL.md")).unwrap(),
            "old\n"
        );
        let canonical_project = std::fs::canonicalize(project).expect("canonical project");
        assert!(outcome.canonical_path.starts_with(canonical_project));
        assert_ne!(outcome.before_sha256, outcome.after_sha256);
        assert!(outcome.unified_diff.contains("-old"));
        assert!(outcome.unified_diff.contains("+new"));
    });
}

#[test]
fn submit_for_review_file_path_emits_spawn_reviewer_to_leader_runtime_session() {
    with_temp_project(|project| {
        let state = start_active_file_session(
            "file submit_for_review spawn",
            "",
            project,
            Some("claude"),
            Some("daemon-file-submit-review"),
        )
        .expect("start session");
        let leader_id = state.leader_id.clone().expect("leader id");
        let joined = temp_env::with_var("CODEX_SESSION_ID", Some("file-review-worker"), || {
            session_service::join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker")
        });
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        let created = create_task(
            &state.session_id,
            &TaskCreateRequest {
                actor: leader_id.clone(),
                title: "review flow task".into(),
                context: None,
                severity: crate::session::types::TaskSeverity::Medium,
                suggested_fix: None,
            },
            None,
        )
        .expect("create task");
        let task_id = created.tasks[0].task_id.clone();
        assign_task(
            &state.session_id,
            &task_id,
            &TaskAssignRequest {
                actor: leader_id.clone(),
                agent_id: worker_id.clone(),
            },
            None,
        )
        .expect("assign task");
        update_task(
            &state.session_id,
            &task_id,
            &TaskUpdateRequest {
                actor: worker_id.clone(),
                status: TaskStatus::InProgress,
                note: None,
            },
            None,
        )
        .expect("move task in_progress");

        submit_for_review(
            &state.session_id,
            &task_id,
            &TaskSubmitForReviewRequest {
                actor: worker_id,
                summary: None,
                suggested_persona: None,
            },
            None,
        )
        .expect("submit_for_review sync");

        let status = session_service::session_status(&state.session_id, project).expect("status");
        let leader_agent = status.agents.get(&leader_id).expect("leader present");
        let leader_signal_session = leader_agent
            .agent_session_id
            .as_deref()
            .expect("leader runtime session");
        let leader_runtime = crate::agents::runtime::runtime_for_name(&leader_agent.runtime)
            .expect("leader runtime");
        let signal_dir = leader_runtime
            .signal_dir(project, leader_signal_session)
            .join("pending");
        let entries: Vec<_> = std::fs::read_dir(&signal_dir)
            .map(|iter| iter.filter_map(Result::ok).collect())
            .unwrap_or_default();
        assert!(
            entries.iter().any(|entry| {
                std::fs::read_to_string(entry.path())
                    .is_ok_and(|contents| contents.contains("spawn_reviewer"))
            }),
            "file submit_for_review must materialize spawn_reviewer under {}",
            signal_dir.display()
        );
        let orchestration_signal_dir = leader_runtime
            .signal_dir(project, &state.session_id)
            .join("pending");
        assert!(
            std::fs::read_dir(&orchestration_signal_dir)
                .map(|mut iter| iter.next().is_none())
                .unwrap_or(true),
            "spawn_reviewer must not target orchestration session id {}",
            orchestration_signal_dir.display()
        );
    });
}
