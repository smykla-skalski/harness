use std::path::Path;

use crate::daemon::db::AsyncDaemonDb;

use super::*;

const TASK_LIFECYCLE_SESSION_ID: &str = "52c91a38-b0d5-58ec-9c6b-fe52dae2cbf1";

#[test]
fn drop_queue_policy_and_status_async_refresh_session_state() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("async-task-lifecycle-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let fixture = task_lifecycle_setup(project).await;
                    task_lifecycle_drop_and_queue(&fixture).await;
                    task_lifecycle_reprioritize_and_complete(&fixture).await;
                });
            },
        );
    });
}

struct TaskLifecycleFixture {
    async_db: AsyncDaemonDb,
    leader_id: String,
    worker_id: String,
    first_task: String,
    second_task: String,
}

async fn task_lifecycle_setup(project: &Path) -> TaskLifecycleFixture {
    let db_path = project
        .parent()
        .expect("project parent")
        .join("daemon.sqlite");
    let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");

    let state = start_direct_session_async(
        &async_db,
        project,
        TASK_LIFECYCLE_SESSION_ID,
        "async task lifecycle",
        "async task lifecycle flow",
        None,
    )
    .await;
    let leader_id = state.leader_id.clone().expect("leader id");
    let joined = join_session_direct_async(
        TASK_LIFECYCLE_SESSION_ID,
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

    let first = create_task_async(
        TASK_LIFECYCLE_SESSION_ID,
        &TaskCreateRequest {
            actor: leader_id.clone(),
            title: "first async task".into(),
            context: None,
            severity: crate::session::types::TaskSeverity::High,
            suggested_fix: None,
        },
        &async_db,
    )
    .await
    .expect("create first task");
    let first_task = first.tasks[0].task_id.clone();
    let second = create_task_async(
        TASK_LIFECYCLE_SESSION_ID,
        &TaskCreateRequest {
            actor: leader_id.clone(),
            title: "second async task".into(),
            context: None,
            severity: crate::session::types::TaskSeverity::Medium,
            suggested_fix: None,
        },
        &async_db,
    )
    .await
    .expect("create second task");
    let second_task = second
        .tasks
        .iter()
        .find(|task| task.title == "second async task")
        .expect("second task")
        .task_id
        .clone();

    TaskLifecycleFixture {
        async_db,
        leader_id,
        worker_id,
        first_task,
        second_task,
    }
}

async fn task_lifecycle_drop_and_queue(fixture: &TaskLifecycleFixture) {
    let dropped = drop_task_async(
        TASK_LIFECYCLE_SESSION_ID,
        &fixture.first_task,
        &crate::daemon::protocol::TaskDropRequest {
            actor: fixture.leader_id.clone(),
            target: crate::daemon::protocol::TaskDropTarget::Agent {
                agent_id: fixture.worker_id.clone(),
            },
            queue_policy: crate::session::types::TaskQueuePolicy::Locked,
            reason: None,
        },
        &fixture.async_db,
        crate::daemon::service::WakeDispatch::none(),
    )
    .await
    .expect("drop first task");
    let first_detail = dropped
        .tasks
        .iter()
        .find(|task| task.task_id == fixture.first_task)
        .expect("first task detail");
    assert_eq!(
        first_detail.assigned_to.as_deref(),
        Some(fixture.worker_id.as_str())
    );

    let _ = drop_task_async(
        TASK_LIFECYCLE_SESSION_ID,
        &fixture.second_task,
        &crate::daemon::protocol::TaskDropRequest {
            actor: fixture.leader_id.clone(),
            target: crate::daemon::protocol::TaskDropTarget::Agent {
                agent_id: fixture.worker_id.clone(),
            },
            queue_policy: crate::session::types::TaskQueuePolicy::Locked,
            reason: None,
        },
        &fixture.async_db,
        crate::daemon::service::WakeDispatch::none(),
    )
    .await
    .expect("queue second task");
}

async fn task_lifecycle_reprioritize_and_complete(fixture: &TaskLifecycleFixture) {
    let reprioritized = update_task_queue_policy_async(
        TASK_LIFECYCLE_SESSION_ID,
        &fixture.second_task,
        &crate::daemon::protocol::TaskQueuePolicyRequest {
            actor: fixture.leader_id.clone(),
            queue_policy: crate::session::types::TaskQueuePolicy::ReassignWhenFree,
        },
        &fixture.async_db,
        crate::daemon::service::WakeDispatch::none(),
    )
    .await
    .expect("update queue policy");
    let second_detail = reprioritized
        .tasks
        .iter()
        .find(|task| task.task_id == fixture.second_task)
        .expect("second task detail");
    assert_eq!(
        second_detail.queue_policy,
        crate::session::types::TaskQueuePolicy::ReassignWhenFree
    );

    let completed = update_task_async(
        TASK_LIFECYCLE_SESSION_ID,
        &fixture.first_task,
        &crate::daemon::protocol::TaskUpdateRequest {
            actor: fixture.leader_id.clone(),
            status: crate::session::types::TaskStatus::Done,
            note: Some("completed asynchronously".into()),
        },
        &fixture.async_db,
        crate::daemon::service::WakeDispatch::none(),
    )
    .await
    .expect("complete first task");
    let second_detail = completed
        .tasks
        .iter()
        .find(|task| task.task_id == fixture.second_task)
        .expect("second task detail");
    assert_eq!(
        second_detail.status,
        crate::session::types::TaskStatus::Open
    );
    let signals = fixture
        .async_db
        .load_signals(TASK_LIFECYCLE_SESSION_ID)
        .await
        .expect("load signals");
    assert!(
        signals
            .iter()
            .any(|signal| signal.agent_id == fixture.worker_id),
        "task lifecycle should refresh indexed signals for the worker"
    );
}
