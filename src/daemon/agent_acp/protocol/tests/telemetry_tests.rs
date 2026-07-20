//! Wire tests for prompt-turn telemetry: the stop reason a turn ends with is
//! recorded on the session state and surfaced as a timeline event.

use super::*;
use crate::agents::acp::supervision::{WatchdogEventEmitter, WatchdogState};

#[derive(Default)]
struct RecordingTurnEmitter {
    turns: Mutex<Vec<String>>,
}

impl WatchdogEventEmitter for RecordingTurnEmitter {
    fn emit_state(&self, _from: WatchdogState, _to: WatchdogState, _reason: Option<&str>) {}

    fn emit_turn_ended(&self, stop_reason: String) {
        self.turns.lock().expect("record turn").push(stop_reason);
    }
}

#[tokio::test]
#[cfg(unix)]
async fn prompt_turn_records_refusal_stop_reason() {
    let project = ok(tempfile::tempdir(), "project tempdir");
    let mut supervisor_child = ok(
        Command::new("sleep").arg("60").spawn(),
        "spawn supervisor child",
    );
    let supervisor = Arc::new(AcpSessionSupervisor::new(
        &supervisor_child,
        SupervisionConfig {
            initialize_timeout: Duration::from_secs(1),
            prompt_timeout: Duration::from_secs(1),
            ..SupervisionConfig::default()
        },
    ));
    let emitter = Arc::new(RecordingTurnEmitter::default());
    supervisor.attach_event_emitter(Arc::clone(&emitter) as _);
    let (client_transport, agent_transport) = Channel::duplex();
    let agent_task = tokio::spawn(super::agents::run_agent_refusing_prompt(agent_transport));
    let (_cancel_tx, cancel_rx) = mpsc::unbounded_channel();
    let (_command_tx, command_rx) = mpsc::unbounded_channel();
    let project_dir = project.path().to_path_buf();
    let protocol_supervisor = Arc::clone(&supervisor);
    let manager = protocol_manager(
        "fake",
        "agent-acp-1",
        "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e",
    );

    let protocol_task = tokio::spawn(async move {
        Client
            .builder()
            .name("harness-test")
            .connect_with(client_transport, async move |connection| {
                run_connection(RunConnectionArgs {
                    connection,
                    project_dir,
                    prompt: Some("do something disallowed".to_string()),
                    session_config: disabled_session_config(),
                    resume_session_id: None,
                    acp_id: "agent-acp-1".to_string(),
                    session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
                    runtime_name: "fake".to_string(),
                    supervisor: protocol_supervisor,
                    initial_prompt_lease: None,
                    cancel_rx,
                    command_rx,
                    session_guard: Arc::new(SessionRouteGuard::default()),
                    manager,
                    credential: None,
                })
                .await
            })
            .await
    });

    tokio::time::sleep(Duration::from_millis(200)).await;
    let state = some(
        supervisor.session_state(),
        "session state should be recorded on the supervisor",
    );
    assert_eq!(state.last_stop_reason.as_deref(), Some("refusal"));
    assert_eq!(
        emitter.turns.lock().expect("recorded turns").clone(),
        vec!["refusal".to_string()]
    );

    protocol_task.abort();
    let _ = protocol_task.await;
    let _ = supervisor_child.kill();
    let _ = supervisor_child.wait();
    agent_task.abort();
    let _ = agent_task.await;
}
