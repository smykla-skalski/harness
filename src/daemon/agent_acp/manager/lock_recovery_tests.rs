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
        model_catalog: None,
        install_hint: None,
        doctor_probe: catalog::DoctorProbe {
            command: command.display().to_string(),
            args: Vec::new(),
        },
        prompt_timeout_seconds: None,
    }
}

fn poison_sessions_lock(manager: &AcpAgentManagerHandle) {
    let state = std::sync::Arc::clone(&manager.state);
    let _ = std::thread::spawn(move || {
        let _guard = state.sessions.lock().expect("sessions lock");
        panic!("poison ACP sessions lock");
    })
    .join();
}

fn poison_process_lifecycle_lock(manager: &AcpAgentManagerHandle) {
    let state = std::sync::Arc::clone(&manager.state);
    let _ = std::thread::spawn(move || {
        let _guard = state
            .process_lifecycle
            .lock()
            .expect("process lifecycle lock");
        panic!("poison ACP process lifecycle lock");
    })
    .join();
}

fn poison_processes_lock(manager: &AcpAgentManagerHandle) {
    let state = std::sync::Arc::clone(&manager.state);
    let _ = std::thread::spawn(move || {
        let _guard = state.processes.lock().expect("processes lock");
        panic!("poison ACP processes lock");
    })
    .join();
}

fn poison_process_fault_locks(manager: &AcpAgentManagerHandle) {
    let state = std::sync::Arc::clone(&manager.state);
    let _ = std::thread::spawn(move || {
        let _backoff = state
            .process_key_backoff_until
            .lock()
            .expect("process key backoff lock");
        panic!("poison ACP process key backoff lock");
    })
    .join();
    let state = std::sync::Arc::clone(&manager.state);
    let _ = std::thread::spawn(move || {
        let _failures = state
            .process_key_failures
            .lock()
            .expect("process key failures lock");
        panic!("poison ACP process key failures lock");
    })
    .join();
    let state = std::sync::Arc::clone(&manager.state);
    let _ = std::thread::spawn(move || {
        let _quarantine = state
            .quarantined_process_keys
            .lock()
            .expect("quarantined process key lock");
        panic!("poison ACP quarantined process key lock");
    })
    .join();
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn manager_lock_recovery_returns_structured_errors_for_poisoned_state() {
    let inspect_manager = manager();
    poison_sessions_lock(&inspect_manager);
    let inspect_error = inspect_manager
        .inspect(Some("sess-1"))
        .expect_err("poisoned sessions lock should surface an error");
    assert!(
        inspect_error
            .to_string()
            .contains("ACP sessions lock poisoned"),
        "unexpected inspect error: {inspect_error}"
    );

    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let lifecycle_manager = manager();
        let descriptor = descriptor(&script);
        let snapshot = lifecycle_manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start");
        poison_process_lifecycle_lock(&lifecycle_manager);
        let stop_error = lifecycle_manager
            .stop(&snapshot.acp_id)
            .expect_err("poisoned lifecycle lock should surface an error");
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
    let process_error = process_manager
        .processes_guard()
        .err()
        .expect("poisoned processes lock should surface an error");
    assert!(
        process_error
            .to_string()
            .contains("ACP processes lock poisoned"),
        "unexpected processes error: {process_error}"
    );

    let fault_manager = manager();
    poison_process_fault_locks(&fault_manager);
    let backoff_error = fault_manager
        .process_key_backoff_until_guard()
        .err()
        .expect("poisoned process key backoff lock should surface an error");
    assert!(
        backoff_error
            .to_string()
            .contains("ACP process key backoff lock poisoned"),
        "unexpected backoff error: {backoff_error}"
    );
    let failures_error = fault_manager
        .process_key_failures_guard()
        .err()
        .expect("poisoned process key failures lock should surface an error");
    assert!(
        failures_error
            .to_string()
            .contains("ACP process key failures lock poisoned"),
        "unexpected failures error: {failures_error}"
    );
    let quarantine_error = fault_manager
        .quarantined_process_keys_guard()
        .err()
        .expect("poisoned quarantined process key lock should surface an error");
    assert!(
        quarantine_error
            .to_string()
            .contains("ACP quarantined process keys lock poisoned"),
        "unexpected quarantine error: {quarantine_error}"
    );
}
