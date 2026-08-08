use std::sync::{Arc, Mutex, OnceLock};

use harness_protocol::daemon::activity::AgentWorkspaceSignalSendRequest;
use sqlx::Row;

use super::*;
use crate::daemon::agent_acp::manager::test_support::seed_daemon_db_for_session_at;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::db_handle::{AsyncDaemonDbHandle, DaemonDbOwnedHandle};
use crate::daemon::db_open::{AsyncDaemonDbConnect, DaemonDbOpen};
use crate::daemon::service::{WakeDispatch, send_agent_workspace_signal_async};

const SESSION_ID: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn native_workspace_wake_persists_acknowledgment_without_read_reconciliation() {
    let temp = TempDir::new().expect("temp");
    with_acp_test_env(&temp, || {
        tokio::task::block_in_place(|| {
            tokio::runtime::Handle::current().block_on(assert_native_workspace_wake(&temp));
        });
    });
}

async fn assert_native_workspace_wake(temp: &TempDir) {
    let (manager, db) = durable_manager(temp).await;
    let script = temp.path().join("gemini-agent.sh");
    write_sleeping_acp_agent(&script);
    let request = AcpAgentStartRequest {
        agent: "gemini".to_string(),
        project_dir: Some(temp.path().display().to_string()),
        ..AcpAgentStartRequest::default()
    };
    let snapshot = manager
        .start_descriptor(SESSION_ID, &request, &descriptor_with_id(&script, "gemini"))
        .expect("start ACP agent");
    let _runtime_session_id = wait_for_runtime_session_id(&manager, SESSION_ID, &snapshot.acp_id);
    let (workspace_id, member_id) = workspace_member(&db, &snapshot.acp_id).await;

    let sent = send_agent_workspace_signal_async(
        &db,
        &workspace_id,
        &member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "native-workspace-wake-test".into(),
            idempotency_key: "native-workspace-wake-1".into(),
            command: "native-workspace-wake".into(),
            message: "Acknowledge through the real ACP wake path".into(),
            action_hint: None,
        },
        WakeDispatch::new(None, Some(&manager)),
    )
    .await
    .expect("send native workspace signal");

    wait_for_raw_durable_ack(&db, &workspace_id, &member_id, &sent.signal.signal_id).await;
    assert!(manager.stop(&snapshot.acp_id).is_ok());
}

async fn durable_manager(temp: &TempDir) -> (AcpAgentManagerHandle, Arc<AsyncDaemonDbHandle>) {
    let db_path = temp.path().join("daemon.sqlite");
    seed_daemon_db_for_session_at(&db_path, temp.path(), SESSION_ID);
    let sync_db = Arc::new(Mutex::new(DaemonDbOwnedHandle(
        DaemonDb::open(&db_path).expect("open synchronous daemon db"),
    )));
    let async_db = Arc::new(AsyncDaemonDbHandle(
        AsyncDaemonDb::connect(&db_path)
            .await
            .expect("open asynchronous daemon db"),
    ));
    let sync_slot = Arc::new(OnceLock::new());
    sync_slot
        .set(sync_db)
        .unwrap_or_else(|_| panic!("set synchronous daemon db"));
    let async_slot = Arc::new(OnceLock::new());
    async_slot
        .set(Arc::clone(&async_db))
        .unwrap_or_else(|_| panic!("set asynchronous daemon db"));
    let (sender, _) = broadcast::channel(16);
    (
        AcpAgentManagerHandle::new_with_async_db(sender, sync_slot, async_slot),
        async_db,
    )
}

async fn workspace_member(db: &AsyncDaemonDbHandle, acp_id: &str) -> (String, String) {
    let daemon_id = crate::daemon::state::ensure_daemon_identity()
        .expect("ensure daemon identity")
        .daemon_id;
    let workspace_id = db
        .reconcile_agent_workspaces(&daemon_id)
        .await
        .expect("reconcile workspace")
        .workspaces
        .into_iter()
        .next()
        .expect("workspace")
        .workspace_id;
    let member_id = db
        .reconcile_agent_workspace_team(&daemon_id, &workspace_id)
        .await
        .expect("reconcile workspace team")
        .team
        .expect("workspace team")
        .members
        .into_iter()
        .find(|member| {
            member
                .managed_identity
                .as_ref()
                .is_some_and(|identity| identity.managed_agent_id == acp_id)
        })
        .expect("ACP workspace member")
        .member_id;
    (workspace_id, member_id)
}

async fn wait_for_raw_durable_ack(
    db: &AsyncDaemonDbHandle,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
) {
    let deadline = tokio::time::Instant::now() + ACP_CONDITION_DEADLINE;
    loop {
        let row = sqlx::query(
            "SELECT status, ack_json FROM agent_workspace_signals
             WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3",
        )
        .bind(workspace_id)
        .bind(member_id)
        .bind(signal_id)
        .fetch_one(db.pool())
        .await
        .expect("load raw durable signal");
        let status: String = row.get("status");
        let acknowledgment: Option<String> = row.get("ack_json");
        if status == "delivered" && acknowledgment.is_some() {
            return;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "ACP wake left raw durable signal at status '{status}' without an acknowledgment"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
