use crate::agents::runtime::runtime_for;
use crate::agents::runtime::signal::{AckResult, read_pending_signals};
use crate::hooks::adapters::HookAgent;

use super::*;

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn repeated_session_restarts_keep_runtime_bindings_scoped_to_each_managed_agent() {
    let Ok(temp) = TempDir::new() else {
        unreachable!();
    };
    with_acp_test_env(&temp, || {
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        let descriptor = descriptor(&script);

        let Ok(first) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!();
        };
        let first_runtime_session = wait_for_runtime_session_id(
            &manager,
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &first.acp_id,
        );

        let Ok(stopped) = manager.stop(&first.acp_id) else {
            unreachable!();
        };
        assert!(matches!(
            stopped.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::SessionStopped,
                ..
            }
        ));

        let Ok(second) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!();
        };
        let second_runtime_session = wait_for_runtime_session_id(
            &manager,
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &second.acp_id,
        );

        assert_ne!(first.agent_id, second.agent_id);

        let state = load_session_state(&manager, "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc");
        let Some(first_agent) = state.agents.get(&first.agent_id) else {
            unreachable!();
        };
        assert_eq!(
            first_agent.managed_agent,
            Some(ManagedAgentRef::acp(first.acp_id.as_str()))
        );
        assert_eq!(
            first_agent.agent_session_id.as_deref(),
            Some(first_runtime_session.as_str())
        );
        assert!(matches!(
            first_agent.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::SessionStopped,
                ..
            }
        ));

        let Some(second_agent) = state.agents.get(&second.agent_id) else {
            unreachable!();
        };
        assert_eq!(
            second_agent.managed_agent,
            Some(ManagedAgentRef::acp(second.acp_id.as_str()))
        );
        assert_eq!(
            second_agent.agent_session_id.as_deref(),
            Some(second_runtime_session.as_str())
        );
        assert_eq!(second_agent.status, AgentStatus::Active);

        assert!(manager.stop(&second.acp_id).is_ok());
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn wake_prompt_rebinds_runtime_session_when_prompt_opens_new_protocol_session() {
    let Ok(temp) = TempDir::new() else {
        unreachable!();
    };
    with_acp_test_env(&temp, || {
        let script = temp.path().join("gemini-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "gemini".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        repoint_project_dir(&manager, temp.path());
        let descriptor = descriptor_with_id(&script, "gemini");
        let Ok(snapshot) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!();
        };
        let runtime = runtime_for(HookAgent::Gemini);
        let initial_runtime_session = wait_for_runtime_session_id(
            &manager,
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &snapshot.acp_id,
        );
        assert_eq!(initial_runtime_session, "acp-session-1");

        manager.dispatch_wake_prompt(
            runtime,
            AcpWakePrompt {
                acp_id: snapshot.acp_id.clone(),
                orchestration_session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
                signal_session_id: initial_runtime_session.clone(),
                signal_dir: runtime.signal_dir(temp.path(), &initial_runtime_session),
                project_dir: temp.path().to_path_buf(),
                prompt: "tell me how are you".into(),
                signal_id: "sig-test-1".into(),
                agent_id: snapshot.agent_id.clone(),
            },
        );

        wait_for_runtime_session_id_value(
            &manager,
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &snapshot.acp_id,
            "acp-session-2",
        );
        assert!(manager.stop(&snapshot.acp_id).is_ok());
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn wake_prompt_acknowledges_signal_in_original_signal_session_dir() {
    let Ok(temp) = TempDir::new() else {
        unreachable!();
    };
    with_acp_test_env(&temp, || {
        let script = temp.path().join("gemini-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "gemini".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        repoint_project_dir(&manager, temp.path());
        let descriptor = descriptor_with_id(&script, "gemini");
        let Ok(snapshot) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!();
        };
        let runtime = runtime_for(HookAgent::Gemini);
        let signal_session_id = wait_for_runtime_session_id(
            &manager,
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &snapshot.acp_id,
        );
        let signal = sample_signal("sig-ack-success");
        let signal_dir = temp.path().join("wake-signals").join(&signal_session_id);
        let Ok(_) = write_signal_file(&signal_dir, &signal) else {
            unreachable!();
        };
        assert_signal_pending(&signal_dir, &signal.signal_id);

        manager.dispatch_wake_prompt(
            runtime,
            AcpWakePrompt {
                acp_id: snapshot.acp_id.clone(),
                orchestration_session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
                signal_session_id: signal_session_id.clone(),
                signal_dir: signal_dir.clone(),
                project_dir: temp.path().to_path_buf(),
                prompt: "please wake up".into(),
                signal_id: signal.signal_id.clone(),
                agent_id: snapshot.agent_id.clone(),
            },
        );

        wait_for_runtime_session_id_value(
            &manager,
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &snapshot.acp_id,
            "acp-session-2",
        );
        let ack = wait_for_signal_ack(&signal_dir, &signal.signal_id);
        assert_eq!(ack.result, AckResult::Accepted);
        assert_eq!(ack.session_id, "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc");
        assert_eq!(ack.agent, signal_session_id);

        let Ok(pending) = read_pending_signals(&signal_dir) else {
            unreachable!();
        };
        assert!(
            pending.is_empty(),
            "pending signal should have been acknowledged"
        );
        assert!(manager.stop(&snapshot.acp_id).is_ok());
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn wake_prompt_skips_ack_when_runtime_rebind_fails() {
    let Ok(temp) = TempDir::new() else {
        unreachable!();
    };
    with_acp_test_env(&temp, || {
        let script = temp.path().join("gemini-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "gemini".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        repoint_project_dir(&manager, temp.path());
        let descriptor = descriptor_with_id(&script, "gemini");
        let Ok(snapshot) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!();
        };
        let runtime = runtime_for(HookAgent::Gemini);
        let signal_session_id = wait_for_runtime_session_id(
            &manager,
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &snapshot.acp_id,
        );
        let signal = sample_signal("sig-ack-skipped");
        let signal_dir = temp.path().join("wake-signals").join(&signal_session_id);
        let Ok(_) = write_signal_file(&signal_dir, &signal) else {
            unreachable!();
        };
        assert_signal_pending(&signal_dir, &signal.signal_id);

        manager.dispatch_wake_prompt(
            runtime,
            AcpWakePrompt {
                acp_id: snapshot.acp_id.clone(),
                orchestration_session_id: "418cf829-6691-5fc0-92b1-8e5013efa2cb".into(),
                signal_session_id: signal_session_id.clone(),
                signal_dir: signal_dir.clone(),
                project_dir: temp.path().to_path_buf(),
                prompt: "please wake up".into(),
                signal_id: signal.signal_id.clone(),
                agent_id: snapshot.agent_id.clone(),
            },
        );

        assert_no_signal_ack_within(&signal_dir, &signal.signal_id, Duration::from_millis(400));
        let returned_signal_dir = runtime.signal_dir(temp.path(), "acp-session-2");
        assert_no_signal_ack_within(
            &returned_signal_dir,
            &signal.signal_id,
            Duration::from_millis(400),
        );

        let Ok(pending) = read_pending_signals(&signal_dir) else {
            unreachable!();
        };
        assert!(
            pending
                .iter()
                .any(|pending| pending.signal_id == signal.signal_id),
            "pending signal should remain file-backed when runtime rebind fails"
        );
        assert_eq!(
            runtime_session_id(
                &manager,
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
                &snapshot.acp_id
            )
            .as_deref(),
            Some(signal_session_id.as_str())
        );
        assert!(manager.stop(&snapshot.acp_id).is_ok());
    });
}
