use std::slice;

use super::*;

const RUNTIME_SESSION: &str = "runtime-008d974f-c6a9-53e5-a62e-d331367c449a";
const ORCHESTRATION_SESSION: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";

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

        assert_eq!(first, ["[signal:inject_context] deliver once"]);
        assert!(retry.is_empty());
        assert!(
            runtime::signal::read_pending_signals(&signal_dir)
                .unwrap()
                .is_empty()
        );
    });
}

#[test]
fn preexisting_ack_repairs_pending_payload_without_emission() {
    with_temp_project(|project| {
        let signal_dir = project.join("signals");
        let signal = signal();
        runtime::signal::write_signal_file(&signal_dir, &signal).unwrap();
        let acknowledgment = runtime::signal::SignalAck {
            signal_id: signal.signal_id.clone(),
            acknowledged_at: "2026-08-06T10:00:01Z".into(),
            result: runtime::signal::AckResult::Accepted,
            agent: RUNTIME_SESSION.into(),
            session_id: ORCHESTRATION_SESSION.into(),
            details: None,
        };
        let acknowledged = runtime::signal::acknowledged_dir(&signal_dir);
        fs::create_dir_all(&acknowledged).unwrap();
        fs::write(
            acknowledged.join(format!("{}.ack.json", signal.signal_id)),
            serde_json::to_string_pretty(&acknowledgment).unwrap(),
        )
        .unwrap();

        let lines = observation::acknowledged_signal_lines(
            &signal_dir,
            slice::from_ref(&signal),
            &identities(),
            project,
            "2026-08-06T10:00:02Z",
        );

        assert!(lines.is_empty());
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
    });
}
