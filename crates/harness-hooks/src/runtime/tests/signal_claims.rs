use std::io::{self, Write};
use std::slice;
use std::sync::{Arc, Barrier};
use std::thread;

use crate::adapters::RenderedHookResponse;
use crate::application::prepare_normalized_context;

use super::*;

const RUNTIME_SESSION: &str = "runtime-008d974f-c6a9-53e5-a62e-d331367c449a";
const ORCHESTRATION_SESSION: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";

struct FailingWriter;

impl Write for FailingWriter {
    fn write(&mut self, _buffer: &[u8]) -> io::Result<usize> {
        Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            "closed hook pipe",
        ))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn signal() -> runtime::signal::Signal {
    runtime::signal::Signal {
        signal_id: "sig-hook-claim".into(),
        version: 1,
        created_at: "2026-08-06T10:00:00Z".into(),
        expires_at: "2099-08-06T10:05:00Z".into(),
        source_agent: "claude".into(),
        command: "inject_context".into(),
        priority: runtime::signal::SignalPriority::Normal,
        payload: runtime::signal::SignalPayload {
            message: "deliver once".into(),
            action_hint: None,
            related_files: Vec::new(),
            metadata: json!(null),
        },
        delivery: runtime::signal::DeliveryConfig {
            max_retries: 3,
            retry_count: 0,
            idempotency_key: None,
        },
    }
}

fn identities() -> SignalIdentities {
    SignalIdentities {
        runtime_session: RUNTIME_SESSION.into(),
        orchestration_session: ORCHESTRATION_SESSION.into(),
        agent: "codex-worker".into(),
    }
}

fn acknowledgment(signal: &runtime::signal::Signal) -> runtime::signal::SignalAck {
    runtime::signal::SignalAck {
        signal_id: signal.signal_id.clone(),
        acknowledged_at: "2026-08-06T10:00:01Z".into(),
        result: runtime::signal::AckResult::Accepted,
        agent: RUNTIME_SESSION.into(),
        session_id: ORCHESTRATION_SESSION.into(),
        details: None,
    }
}

fn write_prepared_ack(signal_dir: &Path, signal: &runtime::signal::Signal) -> PathBuf {
    let acknowledged = runtime::signal::acknowledged_dir(signal_dir);
    fs::create_dir_all(&acknowledged).unwrap();
    fs::write(
        acknowledged.join(format!("{}.ack.json", signal.signal_id)),
        serde_json::to_string_pretty(&acknowledgment(signal)).unwrap(),
    )
    .unwrap();
    acknowledged
}

fn observe_signal(
    project: &Path,
    signal_dir: &Path,
    signal: &runtime::signal::Signal,
    now: &str,
) -> signal_delivery::SignalInjection {
    observation::acknowledged_signal_lines(
        signal_dir,
        slice::from_ref(signal),
        &identities(),
        project,
        now,
    )
}

fn rendered_signal_output(output: String) -> RenderedHookResponse {
    RenderedHookResponse {
        stdout: output,
        exit_code: 0,
        additional_context_rendered: true,
    }
}

fn assert_settlement_is_prepared(
    signal_dir: &Path,
    signal: &runtime::signal::Signal,
    acknowledged: &Path,
) {
    assert!(
        runtime::signal::pending_dir(signal_dir)
            .join(format!("{}.json", signal.signal_id))
            .exists()
    );
    assert!(
        acknowledged
            .join(format!("{}.ack.json", signal.signal_id))
            .exists()
    );
    assert!(
        runtime::signal::read_acknowledgments(signal_dir)
            .unwrap()
            .is_empty()
    );
}

fn assert_recovery_delivers_once(
    project: &Path,
    signal_dir: &Path,
    signal: &runtime::signal::Signal,
) {
    let recovered = observe_signal(project, signal_dir, signal, "2026-08-06T10:00:02Z");
    assert_eq!(recovered.lines, ["[signal:inject_context] deliver once"]);
    let mut output = Vec::new();
    let rendered = rendered_signal_output(recovered.lines.join("\n"));
    signal_delivery::write_hook_output(&mut output, &rendered, recovered.deliveries).unwrap();
    let retry = observe_signal(project, signal_dir, signal, "2026-08-06T10:00:03Z");
    assert!(retry.lines.is_empty());
    assert_eq!(
        runtime::signal::read_acknowledgments(signal_dir)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn only_the_first_hook_claim_emits_a_signal() {
    with_temp_project(|project| {
        let signal_dir = project.join("signals");
        let signal = signal();
        runtime::signal::write_signal_file(&signal_dir, &signal).unwrap();

        let first = observation::acknowledged_signal_lines(
            &signal_dir,
            slice::from_ref(&signal),
            &identities(),
            project,
            "2026-08-06T10:00:01Z",
        );
        let retry = observation::acknowledged_signal_lines(
            &signal_dir,
            slice::from_ref(&signal),
            &identities(),
            project,
            "2026-08-06T10:00:02Z",
        );

        assert_eq!(first.lines, ["[signal:inject_context] deliver once"]);
        assert!(retry.lines.is_empty());
        let mut output = Vec::new();
        let rendered = rendered_signal_output(first.lines.join("\n"));
        signal_delivery::write_hook_output(&mut output, &rendered, first.deliveries).unwrap();
        assert!(
            runtime::signal::read_pending_signals(&signal_dir)
                .unwrap()
                .is_empty()
        );
    });
}

#[test]
fn concurrent_recovery_emits_a_prepared_signal_once() {
    with_temp_project(|project| {
        let signal_dir = project.join("signals");
        let signal = signal();
        runtime::signal::write_signal_file(&signal_dir, &signal).unwrap();
        let acknowledged = write_prepared_ack(&signal_dir, &signal);
        let barrier = Arc::new(Barrier::new(2));
        let attempts = [(), ()].map(|()| {
            let barrier = Arc::clone(&barrier);
            let project = project.to_path_buf();
            let signal_dir = signal_dir.clone();
            let signal = signal.clone();
            thread::spawn(move || {
                barrier.wait();
                observation::acknowledged_signal_lines(
                    &signal_dir,
                    slice::from_ref(&signal),
                    &identities(),
                    &project,
                    "2026-08-06T10:00:02Z",
                )
            })
        });
        let results = attempts.map(|attempt| attempt.join().unwrap());

        assert_eq!(
            results
                .iter()
                .filter(|injection| !injection.lines.is_empty())
                .count(),
            1
        );
        assert!(
            results
                .iter()
                .any(|injection| injection.lines == ["[signal:inject_context] deliver once"])
        );
        let owner = results
            .into_iter()
            .find(|injection| !injection.lines.is_empty())
            .expect("one recovery owner");
        let mut output = Vec::new();
        let rendered = rendered_signal_output(owner.lines.join("\n"));
        signal_delivery::write_hook_output(&mut output, &rendered, owner.deliveries).unwrap();
        assert!(
            runtime::signal::read_pending_signals(&signal_dir)
                .unwrap()
                .is_empty()
        );
        assert!(
            acknowledged
                .join(format!("{}.json", signal.signal_id))
                .exists()
        );
        assert_eq!(
            runtime::signal::read_acknowledgments(&signal_dir)
                .unwrap()
                .len(),
            1
        );
    });
}

#[test]
fn failed_payload_settlement_is_recovered_without_losing_delivery() {
    with_temp_project(|project| {
        let signal_dir = project.join("signals");
        let signal = signal();
        runtime::signal::write_signal_file(&signal_dir, &signal).unwrap();
        let acknowledged = runtime::signal::acknowledged_dir(&signal_dir);
        let obstructed_payload = acknowledged.join(format!("{}.json", signal.signal_id));
        fs::create_dir_all(&obstructed_payload).unwrap();

        let failed = observe_signal(project, &signal_dir, &signal, "2026-08-06T10:00:01Z");
        assert_eq!(failed.lines, ["[signal:inject_context] deliver once"]);
        let mut first_output = Vec::new();
        let rendered = rendered_signal_output(failed.lines.join("\n"));
        signal_delivery::write_hook_output(&mut first_output, &rendered, failed.deliveries)
            .unwrap();
        assert_settlement_is_prepared(&signal_dir, &signal, &acknowledged);

        fs::remove_dir(&obstructed_payload).unwrap();
        assert_recovery_delivers_once(project, &signal_dir, &signal);
    });
}

#[test]
fn failed_stdout_write_keeps_signal_recoverable() {
    with_temp_project(|project| {
        let signal_dir = project.join("signals");
        let signal = signal();
        runtime::signal::write_signal_file(&signal_dir, &signal).unwrap();
        let injection = observe_signal(project, &signal_dir, &signal, "2026-08-06T10:00:01Z");
        let rendered = rendered_signal_output(injection.lines.join("\n"));

        let error =
            signal_delivery::write_hook_output(&mut FailingWriter, &rendered, injection.deliveries)
                .expect_err("closed stdout must reject the delivery");

        assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
        assert_eq!(
            runtime::signal::read_pending_signals(&signal_dir)
                .unwrap()
                .len(),
            1
        );
        assert!(
            runtime::signal::read_acknowledgments(&signal_dir)
                .unwrap()
                .is_empty()
        );
        assert_recovery_delivers_once(project, &signal_dir, &signal);
    });
}

#[test]
fn unrelated_hook_output_cannot_commit_signal_delivery() {
    with_temp_project(|project| {
        let signal_dir = project.join("signals");
        let signal = signal();
        runtime::signal::write_signal_file(&signal_dir, &signal).unwrap();
        let injection = observe_signal(project, &signal_dir, &signal, "2026-08-06T10:00:01Z");
        let rendered = RenderedHookResponse {
            stdout: r#"{"decision":"block","reason":"unrelated denial"}"#.into(),
            exit_code: 0,
            additional_context_rendered: false,
        };

        let error =
            signal_delivery::write_hook_output(&mut Vec::new(), &rendered, injection.deliveries)
                .expect_err("output without signal context must not commit delivery");

        assert_eq!(error.kind(), io::ErrorKind::WriteZero);
        assert_eq!(
            runtime::signal::read_pending_signals(&signal_dir)
                .unwrap()
                .len(),
            1
        );
        assert!(
            runtime::signal::read_acknowledgments(&signal_dir)
                .unwrap()
                .is_empty()
        );
        assert_recovery_delivers_once(project, &signal_dir, &signal);
    });
}

#[test]
fn copilot_delivers_pending_signal_after_tool_use() {
    with_temp_project(|project| {
        let agent = HookAgent::Copilot;
        let event = NormalizedEvent::AfterToolUse;
        let signal_dir = runtime::runtime_for(agent).signal_dir(project, RUNTIME_SESSION);
        runtime::signal::write_signal_file(&signal_dir, &signal()).unwrap();
        let raw = serde_json::to_vec(&json!({
            "sessionId": RUNTIME_SESSION,
            "cwd": project,
            "toolName": "bash",
            "toolArgs": { "command": "true" },
            "toolResult": { "exitCode": 0 }
        }))
        .unwrap();
        let parsed = adapter_for(agent).parse_input(&raw).unwrap();
        let context = prepare_normalized_context(parsed, "suite:run", event.clone());

        assert_eq!(context.session.session_id, RUNTIME_SESSION);
        assert_eq!(context.tool.as_ref().unwrap().input_raw["command"], "true");

        let (result, deliveries) =
            inject_pending_signals(agent, &context, NormalizedHookResult::allow());
        let rendered = adapter_for(agent).render_output(&result, &event);
        let mut output = Vec::new();
        signal_delivery::write_hook_output(&mut output, &rendered, deliveries).unwrap();

        assert!(rendered.additional_context_rendered);
        assert!(String::from_utf8(output).unwrap().contains("deliver once"));
        assert!(
            runtime::signal::read_pending_signals(&signal_dir)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            runtime::signal::read_acknowledgments(&signal_dir)
                .unwrap()
                .len(),
            1
        );
    });
}
