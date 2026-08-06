use super::super::*;
use crate::daemon::db::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::db_open::AsyncDaemonDbConnect;

#[test]
fn remove_agent_async_direct_sends_abort_signal() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-remove-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");
                let async_db = AsyncDaemonDbHandle(async_db);
                let state = start_direct_session_async(
                    &async_db,
                    project,
                    "b008af80-54bd-5d3d-aef2-a6cd524b8684",
                    "async remove session",
                    "async remove",
                    None,
                )
                .await;
                let leader_id = state.leader_id.clone().expect("leader id");
                let joined = join_session_direct_async(
                    "b008af80-54bd-5d3d-aef2-a6cd524b8684",
                    &crate::daemon::protocol::SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: None,
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("join session");
                let worker_id = joined
                    .agents
                    .keys()
                    .find(|agent_id| agent_id.starts_with("codex-"))
                    .expect("worker id")
                    .clone();

                let detail = remove_agent_async(
                    "b008af80-54bd-5d3d-aef2-a6cd524b8684",
                    &worker_id,
                    &AgentRemoveRequest { actor: leader_id },
                    &async_db,
                )
                .await
                .expect("remove via async db");

                assert!(
                    detail
                        .agents
                        .iter()
                        .all(|agent| agent.agent_id != worker_id),
                    "removed agents should disappear from session detail"
                );
                assert_eq!(detail.signals.len(), 1);
                assert_eq!(detail.signals[0].agent_id, worker_id);
                assert_eq!(detail.signals[0].signal.command, "abort");
                assert_eq!(detail.signals[0].status, SessionSignalStatus::Pending);
                let durable_result = sqlx::query_as::<_, (String, String)>(
                    "SELECT member.membership_status, operation.outcome
                     FROM agent_workspace_member_provenance provenance
                     JOIN agent_workspace_members member
                       ON member.workspace_id = provenance.workspace_id
                      AND member.member_id = provenance.member_id
                     JOIN agent_workspace_member_operations operation
                       ON operation.workspace_id = member.workspace_id
                      AND operation.member_id = member.member_id
                     WHERE provenance.source_session_id = ?1
                       AND provenance.source_agent_id = ?2
                     ORDER BY operation.operation_sequence DESC
                     LIMIT 1",
                )
                .bind("b008af80-54bd-5d3d-aef2-a6cd524b8684")
                .bind(&worker_id)
                .fetch_one(async_db.pool())
                .await
                .expect("load preflighted durable membership removal");
                assert_eq!(durable_result.0, "removed");
                assert_eq!(durable_result.1, "succeeded");
            });
        });
    });
}

#[test]
fn remove_agent_async_records_committed_removal_when_finalization_fails() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("async-remove-mirror-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = project
                        .parent()
                        .expect("project parent")
                        .join("daemon.sqlite");
                    let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                        .await
                        .expect("open async daemon db");
                    let async_db = AsyncDaemonDbHandle(async_db);
                    let session_id = "c28400e3-15ec-54b3-a96b-35a19efef0eb";
                    let state = start_direct_session_async(
                        &async_db,
                        project,
                        session_id,
                        "async remove mirror failure",
                        "async remove mirror failure",
                        None,
                    )
                    .await;
                    let leader_id = state.leader_id.clone().expect("leader id");
                    let joined = join_session_direct_async(
                        session_id,
                        &crate::daemon::protocol::SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            fallback_role: None,
                            capabilities: vec![],
                            name: None,
                            project_dir: project.to_string_lossy().into(),
                            persona: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("join session");
                    let worker_id = joined
                        .agents
                        .keys()
                        .find(|agent_id| agent_id.starts_with("codex-"))
                        .expect("worker id")
                        .clone();
                    let daemon_id = crate::daemon::state::ensure_daemon_identity()
                        .expect("ensure daemon identity")
                        .daemon_id;
                    let workspace_id = async_db
                        .reconcile_agent_workspaces(&daemon_id)
                        .await
                        .expect("reconcile workspace")
                        .workspaces[0]
                        .workspace_id
                        .clone();
                    async_db
                        .reconcile_agent_workspace_team(&daemon_id, &workspace_id)
                        .await
                        .expect("create durable team");
                    sqlx::query(
                        "CREATE TRIGGER fail_post_removal_log
                     BEFORE INSERT ON session_log
                     BEGIN
                         SELECT RAISE(ABORT, 'forced post-removal log failure');
                     END",
                    )
                    .execute(async_db.pool())
                    .await
                    .expect("install post-removal failure");
                    let error = remove_agent_async(
                        session_id,
                        &worker_id,
                        &AgentRemoveRequest { actor: leader_id },
                        &async_db,
                    )
                    .await
                    .expect_err("post-removal log must fail after the membership change commits");
                    assert!(
                        error.message().contains("forced post-removal log failure"),
                        "unexpected post-removal failure: {}",
                        error.message()
                    );

                    let recorded = sqlx::query_as::<_, (String, String, String, String)>(
                        "SELECT member.membership_status, operation.outcome,
                            operation.before_state, operation.after_state
                     FROM agent_workspace_members member
                     JOIN agent_workspace_member_operations operation
                       ON operation.workspace_id = member.workspace_id
                      AND operation.member_id = member.member_id
                     WHERE member.workspace_id = ?1
                     ORDER BY operation.operation_sequence DESC
                     LIMIT 1",
                    )
                    .bind(&workspace_id)
                    .fetch_one(async_db.pool())
                    .await
                    .expect("load committed membership removal result");
                    assert_eq!(recorded.0, "removed");
                    assert_eq!(recorded.1, "succeeded");
                    assert_eq!(recorded.2, "joined");
                    assert_eq!(recorded.3, "removed");
                });
            },
        );
    });
}

#[test]
fn end_session_async_direct_marks_inactive() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-end-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");
                let async_db = AsyncDaemonDbHandle(async_db);
                let state = start_direct_session_async(
                    &async_db,
                    project,
                    "19bd7483-41f5-53fa-8391-c65b30390c1d",
                    "async end session",
                    "async end",
                    None,
                )
                .await;
                let leader_id = state.leader_id.clone().expect("leader id");
                let joined = join_session_direct_async(
                    "19bd7483-41f5-53fa-8391-c65b30390c1d",
                    &crate::daemon::protocol::SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: None,
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("join session");
                let worker_id = joined
                    .agents
                    .keys()
                    .find(|agent_id| agent_id.starts_with("codex-"))
                    .expect("worker id")
                    .clone();

                let detail = end_session_async(
                    "19bd7483-41f5-53fa-8391-c65b30390c1d",
                    &SessionEndRequest { actor: leader_id },
                    &async_db,
                )
                .await
                .expect("end session via async db");

                assert_eq!(detail.session.status, SessionStatus::Ended);
                assert_eq!(detail.session.metrics.active_agent_count, 0);
                assert!(detail.session.leader_id.is_none());
                assert!(detail.agents.is_empty());
                assert_eq!(detail.signals.len(), 2);
                assert!(
                    detail
                        .signals
                        .iter()
                        .any(|signal| signal.agent_id == worker_id),
                    "worker leave signal should remain visible in async detail"
                );
            });
        });
    });
}

#[test]
fn start_session_direct_async_creates_in_sqlite() {
    with_temp_project(|project| {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let db_path = project
                .parent()
                .expect("project parent")
                .join("daemon.sqlite");
            let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                .await
                .expect("open async daemon db");
            let async_db = AsyncDaemonDbHandle(async_db);

            let session_id = "00000000-0000-4000-8000-000000000501";
            let state = start_session_direct_async(
                &crate::daemon::protocol::SessionStartRequest {
                    title: "async direct start session".into(),
                    context: "async direct start".into(),
                    session_id: Some(session_id.into()),
                    project_dir: project.to_string_lossy().into(),
                    policy_preset: None,
                    base_ref: None,
                },
                &async_db,
            )
            .await
            .expect("start session via async db");

            assert_eq!(state.context, "async direct start");
            assert_eq!(state.status, SessionStatus::AwaitingLeader);
            assert!(state.leader_id.is_none());
            assert!(state.agents.is_empty());
            assert_eq!(state.metrics.agent_count, 0);

            let resolved = async_db
                .resolve_session(session_id)
                .await
                .expect("resolve")
                .expect("present");
            assert_eq!(resolved.state.context, "async direct start");
            assert_eq!(resolved.state.status, SessionStatus::AwaitingLeader);
            assert!(resolved.state.leader_id.is_none());
            assert!(resolved.state.agents.is_empty());
            assert_eq!(
                resolved.project.project_dir.as_deref(),
                Some(project.canonicalize().expect("canonical project").as_path())
            );
        });
    });
}

#[test]
fn join_session_direct_async_adds_agent() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-join-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");
                let async_db = AsyncDaemonDbHandle(async_db);

                let session_id = "00000000-0000-4000-8000-000000000502";
                start_session_direct_async(
                    &crate::daemon::protocol::SessionStartRequest {
                        title: "async join test session".into(),
                        context: "async join test".into(),
                        session_id: Some(session_id.into()),
                        project_dir: project.to_string_lossy().into(),
                        policy_preset: None,
                        base_ref: None,
                    },
                    &async_db,
                )
                .await
                .expect("start session");

                let joined = join_session_direct_async(
                    session_id,
                    &crate::daemon::protocol::SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: None,
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("join session via async db");

                assert_eq!(joined.status, SessionStatus::AwaitingLeader);
                assert!(joined.leader_id.is_none());
                assert_eq!(joined.agents.len(), 1);

                let resolved = async_db
                    .resolve_session(session_id)
                    .await
                    .expect("resolve")
                    .expect("present");
                assert_eq!(resolved.state.status, SessionStatus::AwaitingLeader);
                assert!(resolved.state.leader_id.is_none());
                assert_eq!(resolved.state.agents.len(), 1);
            });
        });
    });
}
