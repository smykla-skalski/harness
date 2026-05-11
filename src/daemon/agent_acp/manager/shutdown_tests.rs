use std::path::Path;

use tempfile::TempDir;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::daemon::agent_acp::manager::test_support::{seeded_manager, write_sleeping_acp_agent};
use crate::feature_flags;

fn manager() -> AcpAgentManagerHandle {
    seeded_manager()
}

fn descriptor(command: &Path) -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: "fake".to_string(),
        display_name: "Fake ACP".to_string(),
        capabilities: Vec::new(),
        launch_command: command.display().to_string(),
        launch_args: Vec::new(),
        env_passthrough: Vec::new(),
        spawn_configuration: Default::default(),
        model_catalog: None,
        install_hint: None,
        session_configuration: Default::default(),
        doctor_probe: catalog::DoctorProbe {
            command: command.display().to_string(),
            args: Vec::new(),
        },
        prompt_timeout_seconds: None,
        excluded_from_initial_default: false,
    }
}

fn wait_until_disconnected(manager: &AcpAgentManagerHandle, acp_id: &str) -> AcpAgentSnapshot {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        let Ok(snapshot) = manager.get(acp_id) else {
            unreachable!("refresh");
        };
        if matches!(snapshot.status, AgentStatus::Disconnected { .. }) {
            return snapshot;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "timed out waiting for ACP process to disconnect"
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn shutdown_all_drains_live_sessions_and_blocks_new_starts() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!("temp");
        };
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        let descriptor = descriptor(&script);
        let Ok(snapshot) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!("start");
        };

        let Ok(()) = manager.shutdown_all() else {
            unreachable!("shutdown all");
        };
        let disconnected = wait_until_disconnected(&manager, &snapshot.acp_id);
        assert!(matches!(
            disconnected.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::DaemonShutdown,
                ..
            }
        ));

        let Err(restart_error) = manager.start_descriptor(
            "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
            &request,
            &descriptor,
        ) else {
            unreachable!("shutdown should block new ACP starts");
        };
        assert!(
            restart_error.to_string().contains("shutting down"),
            "unexpected restart error: {restart_error}"
        );
    });
}
