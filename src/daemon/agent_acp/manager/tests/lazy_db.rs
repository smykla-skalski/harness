use std::sync::{Arc, OnceLock};

use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::daemon::agent_acp::manager::test_support::{
    seed_daemon_db_at, write_sleeping_acp_agent,
};
use crate::daemon::state;

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn start_descriptor_lazily_opens_canonical_db_for_orchestration_registration() {
    let sandbox = TempDir::new().expect("sandbox");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
            state::ensure_daemon_dirs().expect("ensure daemon dirs");
            let db_path = state::daemon_root().join("harness.db");
            seed_daemon_db_at(&db_path);

            let script = sandbox.path().join("fake-agent.sh");
            write_sleeping_acp_agent(&script);
            let request = AcpAgentStartRequest {
                agent: "fake".to_string(),
                project_dir: Some(sandbox.path().display().to_string()),
                ..AcpAgentStartRequest::default()
            };
            let descriptor = super::descriptor(&script);
            let (sender, _) = broadcast::channel(16);
            let manager = AcpAgentManagerHandle::new(sender, Arc::new(OnceLock::new()));

            let snapshot = manager
                .start_descriptor("sess-1", &request, &descriptor)
                .expect("start with lazy-opened daemon db");

            assert!(
                manager.state.db.get().is_some(),
                "manager should cache opened db"
            );
            let state = super::load_session_state(&manager, "sess-1");
            let agent = state
                .agents
                .get(&snapshot.agent_id)
                .expect("registered ACP agent");
            assert_eq!(
                agent.managed_agent,
                Some(ManagedAgentRef::acp(&snapshot.acp_id))
            );
            assert_eq!(agent.status, AgentStatus::Active);

            manager.stop(&snapshot.acp_id).expect("stop");
        });
    });
}
