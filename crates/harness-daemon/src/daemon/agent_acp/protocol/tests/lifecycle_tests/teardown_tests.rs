//! Wire tests for the session lifecycle slice 4c owns: resuming a prior
//! session on restart, and closing sessions on the way down.

use super::*;

/// A restart picks the conversation back up rather than starting over.
#[tokio::test]
#[cfg(unix)]
async fn a_resume_target_opens_the_prior_session_with_its_inputs() {
    let harness = lifecycle_harness_resuming(
        run_agent_recording_session_resume,
        session_config_with_inputs(),
        Some("acp-session-prior".to_string()),
    );

    let record = harness.await_recorded("resume:").await;

    assert_eq!(
        record,
        "resume:acp-session-prior:inputs:mcp=descriptor-server,start-server:dirs="
    );
    assert!(
        !harness
            .recorded()
            .iter()
            .any(|operation| operation.starts_with("new:")),
        "a resumed start must not also open a new session; got {:?}",
        harness.recorded()
    );

    harness.shutdown().await;
}

/// The stored id came from a past run, so an agent that cannot resume must
/// still yield a working session rather than failing the start.
#[tokio::test]
#[cfg(unix)]
async fn a_resume_target_falls_back_to_a_new_session_without_the_capability() {
    let harness = lifecycle_harness_resuming(
        run_agent_recording_session_inputs,
        session_config_with_inputs(),
        Some("acp-session-prior".to_string()),
    );

    let record = harness.await_recorded("new:").await;

    assert_eq!(
        record, "new:mcp=descriptor-server,start-server:dirs=/work/descriptor,/work/start",
        "the fallback session still carries the declared inputs"
    );

    harness.shutdown().await;
}

/// Teardown closes what the connection still routes so the agent can keep the
/// session, instead of losing it to the kill that follows.
#[tokio::test]
#[cfg(unix)]
async fn close_routed_sessions_closes_the_live_session() {
    let harness = lifecycle_harness(run_agent_recording_session_lifecycle);

    let closed = ok(
        harness
            .dispatch(|response_tx| ProtocolCommand::CloseRoutedSessions {
                budget: Duration::from_secs(2),
                response_tx,
            })
            .await,
        "the close sweep should succeed",
    );

    assert_eq!(closed, 1, "the routed session should have been closed");
    assert!(
        harness
            .recorded()
            .contains(&"close:acp-session-1".to_string()),
        "agent should have received close for the routed session; got {:?}",
        harness.recorded()
    );

    harness.shutdown().await;
}

#[tokio::test]
#[cfg(unix)]
async fn close_routed_sessions_skips_an_agent_without_the_capability() {
    let harness = lifecycle_harness(run_agent_recording_initialize_contract);

    let closed = ok(
        harness
            .dispatch(|response_tx| ProtocolCommand::CloseRoutedSessions {
                budget: Duration::from_secs(2),
                response_tx,
            })
            .await,
        "the sweep must not fail an agent that cannot close",
    );

    assert_eq!(closed, 0);
    assert!(
        !harness
            .recorded()
            .iter()
            .any(|operation| operation.starts_with("close:")),
        "agent must not receive close without the capability"
    );

    harness.shutdown().await;
}

/// One wedged agent must not stretch shutdown: the budget covers the whole
/// sweep, not each session in it.
#[tokio::test]
#[cfg(unix)]
async fn close_routed_sessions_gives_up_within_its_budget() {
    let harness = lifecycle_harness(run_agent_never_answering_close);

    let started = std::time::Instant::now();
    let closed = ok(
        harness
            .dispatch(|response_tx| ProtocolCommand::CloseRoutedSessions {
                budget: Duration::from_millis(200),
                response_tx,
            })
            .await,
        "the sweep must return even when the agent never answers",
    );

    assert_eq!(closed, 0, "a session that never answered is not closed");
    assert!(
        started.elapsed() < Duration::from_secs(1),
        "sweep took {:?}, past its budget",
        started.elapsed()
    );

    harness.shutdown().await;
}

/// Detaching one logical session ends it on the agent too, rather than leaving
/// it open on a process other sessions keep alive.
#[tokio::test]
#[cfg(unix)]
async fn detaching_a_session_closes_it_on_the_agent() {
    let harness = lifecycle_harness(run_agent_recording_session_lifecycle);

    ok(
        harness
            .dispatch(|response_tx| ProtocolCommand::DetachTarget {
                target: RouteTarget {
                    acp_id: "agent-acp-1".to_string(),
                    session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
                },
                response_tx,
            })
            .await,
        "detach should succeed",
    );

    assert!(
        harness
            .recorded()
            .contains(&"close:acp-session-1".to_string()),
        "agent should have received close for the detached session; got {:?}",
        harness.recorded()
    );

    harness.shutdown().await;
}
