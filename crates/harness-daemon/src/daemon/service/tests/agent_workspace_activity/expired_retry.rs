use harness_kernel::errors::CliError;

use super::*;
use crate::daemon::protocol::{CodexRunSnapshot, CodexSteerRequest};
use crate::daemon::service::wake_route::CodexWake;

struct ForbiddenCodexWake;

impl CodexWake for ForbiddenCodexWake {
    fn steer(
        &self,
        _run_id: &str,
        _request: &CodexSteerRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        panic!("an expired signal must not wake its managed agent")
    }
}

#[test]
fn expired_signal_retry_settles_without_recreating_runtime_delivery() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("workspace-activity-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(assert_expired_retry_settles(project));
            },
        );
    });
}

async fn assert_expired_retry_settles(project: &std::path::Path) {
    let fixture = seed_workspace_activity_member(project).await;
    sqlx::query(
        "UPDATE agent_workspace_members
         SET managed_agent_kind = 'codex', managed_agent_id = 'forbidden-expired-wake'
         WHERE workspace_id = ?1 AND member_id = ?2",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .execute(fixture.db.pool())
    .await
    .expect("route durable member through Codex");
    let request = AgentWorkspaceSignalSendRequest {
        actor: "expired-retry-client".into(),
        idempotency_key: "expired-retry-1".into(),
        command: "expired-retry".into(),
        message: "Do not revive expired work".into(),
        action_hint: None,
    };
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none(),
    )
    .await
    .expect("send signal before expiry");
    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    let pending_path =
        runtime::signal::pending_dir(&signal_dir).join(format!("{}.json", sent.signal.signal_id));
    std::fs::remove_file(&pending_path).expect("simulate missing runtime payload after expiry");
    sqlx::query(
        "UPDATE agent_workspace_signals
         SET signal_json = json_set(signal_json, '$.expires_at', '2000-01-01T00:00:00Z')
         WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .bind(&sent.signal.signal_id)
    .execute(fixture.db.pool())
    .await
    .expect("expire durable signal");

    let settled = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none().with_codex(Some(&ForbiddenCodexWake)),
    )
    .await
    .expect("settle expired retry");
    assert_eq!(settled.status, SessionSignalStatus::Expired);
    assert_eq!(
        settled.acknowledgment.expect("durable expiry").result,
        AckResult::Expired
    );
    assert!(
        !pending_path.exists(),
        "expired payload must not be recreated"
    );
}
