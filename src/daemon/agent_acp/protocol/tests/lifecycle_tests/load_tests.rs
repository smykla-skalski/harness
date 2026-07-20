//! Wire tests for `session/load`: the replay-carrying way to pick up a prior
//! session when the agent cannot resume.

use super::*;

/// Without `resume`, a stored id is still worth picking up through `load`.
#[tokio::test]
#[cfg(unix)]
async fn a_prior_session_loads_when_the_agent_cannot_resume() {
    let harness = lifecycle_harness_resuming(
        run_agent_replaying_session_load,
        session_config_with_inputs(),
        Some("acp-session-prior".to_string()),
    );

    let record = harness.await_recorded("load:").await;

    assert_eq!(
        record,
        "load:acp-session-prior:inputs:mcp=descriptor-server,start-server:dirs=/work/descriptor,/work/start"
    );
    assert!(
        !harness
            .recorded()
            .iter()
            .any(|operation| operation.starts_with("new:")),
        "a loaded start must not also open a new session; got {:?}",
        harness.recorded()
    );

    harness.shutdown().await;
}

/// An agent that offers both is picked up by resume, not load: resume
/// restores the same context without making the agent replay a conversation
/// harness already holds.
#[tokio::test]
#[cfg(unix)]
async fn resume_is_preferred_when_the_agent_offers_both() {
    let harness = lifecycle_harness_resuming(
        run_agent_advertising_resume_and_load,
        session_config_with_inputs(),
        Some("acp-session-prior".to_string()),
    );

    let record = harness.await_recorded("resume:").await;

    assert_eq!(record, "resume:acp-session-prior");
    assert!(
        !harness
            .recorded()
            .iter()
            .any(|operation| operation.starts_with("load:")),
        "resume must be chosen over load; got {:?}",
        harness.recorded()
    );

    harness.shutdown().await;
}

/// The stored id came from a past run, so an agent that has dropped that
/// session must still yield a working one.
#[tokio::test]
#[cfg(unix)]
async fn a_refused_load_falls_back_to_a_new_session() {
    let harness = lifecycle_harness_resuming(
        run_agent_refusing_session_load,
        session_config_with_inputs(),
        Some("acp-session-prior".to_string()),
    );

    let record = harness.await_recorded("new:").await;

    assert_eq!(
        record, "new:mcp=descriptor-server,start-server:dirs=",
        "the fallback session still carries the declared inputs"
    );
    assert!(
        harness
            .recorded()
            .iter()
            .any(|operation| operation == "load-refused:acp-session-prior"),
        "the fallback should follow a real load attempt; got {:?}",
        harness.recorded()
    );

    harness.shutdown().await;
}
