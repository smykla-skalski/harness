use std::path::Path;

use tempfile::TempDir;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::daemon::agent_acp::manager::test_support::{seeded_manager, write_sleeping_acp_agent};

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

fn poison_sessions_lock(manager: &AcpAgentManagerHandle) {
    let state = std::sync::Arc::clone(&manager.state);
    let result = std::thread::spawn(move || {
        let Ok(_guard) = state.sessions.lock() else {
            unreachable!("sessions lock");
        };
        std::panic::panic_any("poison ACP sessions lock");
    })
    .join();
    assert!(result.is_err(), "poison thread should panic");
}

fn poison_process_lifecycle_lock(manager: &AcpAgentManagerHandle) {
    let state = std::sync::Arc::clone(&manager.state);
    let result = std::thread::spawn(move || {
        let Ok(_guard) = state.process_lifecycle.lock() else {
            unreachable!("process lifecycle lock");
        };
        std::panic::panic_any("poison ACP process lifecycle lock");
    })
    .join();
    assert!(result.is_err(), "poison thread should panic");
}

fn poison_processes_lock(manager: &AcpAgentManagerHandle) {
    let state = std::sync::Arc::clone(&manager.state);
    let result = std::thread::spawn(move || {
        let Ok(_guard) = state.processes.lock() else {
            unreachable!("processes lock");
        };
        std::panic::panic_any("poison ACP processes lock");
    })
    .join();
    assert!(result.is_err(), "poison thread should panic");
}

fn poison_process_fault_locks(manager: &AcpAgentManagerHandle) {
    let state = std::sync::Arc::clone(&manager.state);
    let backoff_result = std::thread::spawn(move || {
        let Ok(_backoff) = state.process_key_backoff_until.lock() else {
            unreachable!("process key backoff lock");
        };
        std::panic::panic_any("poison ACP process key backoff lock");
    })
    .join();
    assert!(backoff_result.is_err(), "poison thread should panic");
    let state = std::sync::Arc::clone(&manager.state);
    let failures_result = std::thread::spawn(move || {
        let Ok(_failures) = state.process_key_failures.lock() else {
            unreachable!("process key failures lock");
        };
        std::panic::panic_any("poison ACP process key failures lock");
    })
    .join();
    assert!(failures_result.is_err(), "poison thread should panic");
    let state = std::sync::Arc::clone(&manager.state);
    let quarantine_result = std::thread::spawn(move || {
        let Ok(_quarantine) = state.quarantined_process_keys.lock() else {
            unreachable!("quarantined process key lock");
        };
        std::panic::panic_any("poison ACP quarantined process key lock");
    })
    .join();
    assert!(quarantine_result.is_err(), "poison thread should panic");
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn manager_lock_recovery_returns_structured_errors_for_poisoned_state() {
    let inspect_manager = manager();
    poison_sessions_lock(&inspect_manager);
    let Err(inspect_error) = inspect_manager.inspect(Some("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"))
    else {
        unreachable!("poisoned sessions lock should surface an error");
    };
    assert!(
        inspect_error
            .to_string()
            .contains("ACP sessions lock poisoned"),
        "unexpected inspect error: {inspect_error}"
    );

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
        let lifecycle_manager = manager();
        let descriptor = descriptor(&script);
        let Ok(snapshot) = lifecycle_manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!("start");
        };
        poison_process_lifecycle_lock(&lifecycle_manager);
        let Err(stop_error) = lifecycle_manager.stop(&snapshot.acp_id) else {
            unreachable!("poisoned lifecycle lock should surface an error");
        };
        assert!(
            stop_error
                .to_string()
                .contains("ACP process lifecycle lock poisoned"),
            "unexpected stop error: {stop_error}"
        );
    });
}

#[test]
fn manager_guard_helpers_return_structured_errors_for_other_poisoned_locks() {
    let process_manager = manager();
    poison_processes_lock(&process_manager);
    let Err(process_error) = process_manager.processes_guard() else {
        unreachable!("poisoned processes lock should surface an error");
    };
    assert!(
        process_error
            .to_string()
            .contains("ACP processes lock poisoned"),
        "unexpected processes error: {process_error}"
    );

    let fault_manager = manager();
    poison_process_fault_locks(&fault_manager);
    let Err(backoff_error) = fault_manager.process_key_backoff_until_guard() else {
        unreachable!("poisoned process key backoff lock should surface an error");
    };
    assert!(
        backoff_error
            .to_string()
            .contains("ACP process key backoff lock poisoned"),
        "unexpected backoff error: {backoff_error}"
    );
    let Err(failures_error) = fault_manager.process_key_failures_guard() else {
        unreachable!("poisoned process key failures lock should surface an error");
    };
    assert!(
        failures_error
            .to_string()
            .contains("ACP process key failures lock poisoned"),
        "unexpected failures error: {failures_error}"
    );
    let Err(quarantine_error) = fault_manager.quarantined_process_keys_guard() else {
        unreachable!("poisoned quarantined process key lock should surface an error");
    };
    assert!(
        quarantine_error
            .to_string()
            .contains("ACP quarantined process keys lock poisoned"),
        "unexpected quarantine error: {quarantine_error}"
    );
}
