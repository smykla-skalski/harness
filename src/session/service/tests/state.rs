use super::*;

#[test]
fn apply_join_session_idempotent_by_marker() {
    let now = "2026-04-12T00:00:00Z";
    let mut state = build_new_session("test", "test", "s-idem", "claude", None, now);

    let caps = vec![
        "agent-tui".to_string(),
        "agent-tui:agent-tui-abc123".to_string(),
    ];

    let first = apply_join_session(
        &mut state,
        "codex worker",
        "codex",
        SessionRole::Worker,
        &caps,
        None,
        now,
        None,
        None,
    )
    .expect("first join");

    let second = apply_join_session(
        &mut state,
        "codex worker",
        "codex",
        SessionRole::Worker,
        &caps,
        None,
        now,
        None,
        None,
    )
    .expect("second join");

    assert_eq!(first, second, "same marker should return same agent_id");
    // Only one worker, no duplicate
    assert_eq!(state.agents.len(), 1);
}

#[test]
fn apply_join_session_different_markers_create_distinct() {
    let now = "2026-04-12T00:00:00Z";
    let mut state = build_new_session("test", "test", "s-diff", "claude", None, now);

    let caps_a = vec![
        "agent-tui".to_string(),
        "agent-tui:agent-tui-aaa".to_string(),
    ];
    let caps_b = vec![
        "agent-tui".to_string(),
        "agent-tui:agent-tui-bbb".to_string(),
    ];

    let first = apply_join_session(
        &mut state,
        "codex worker A",
        "codex",
        SessionRole::Worker,
        &caps_a,
        None,
        now,
        None,
        None,
    )
    .expect("first join");

    let second = apply_join_session(
        &mut state,
        "codex worker B",
        "codex",
        SessionRole::Worker,
        &caps_b,
        None,
        now,
        None,
        None,
    )
    .expect("second join");

    assert_ne!(
        first, second,
        "different markers should create distinct agents"
    );
    // Two distinct workers
    assert_eq!(state.agents.len(), 2);
}

#[test]
fn register_runtime_session_preserves_identity_classes() {
    let now = "2026-04-12T00:00:00Z";
    let managed_agent = crate::session::types::ManagedAgentRef::tui("tui-123");
    let mut state = build_new_session("test", "test", "s-runtime", "claude", None, now);

    let agent_id = apply_join_session(
        &mut state,
        "codex worker",
        "codex",
        SessionRole::Worker,
        &[],
        None,
        now,
        None,
        Some(managed_agent.clone()),
    )
    .expect("join worker");

    let changed = apply_register_agent_runtime_session(
        &mut state,
        "codex",
        &managed_agent,
        "runtime-123",
        now,
    )
    .expect("register runtime session");

    assert!(changed);
    assert_eq!(
        find_agent_by_managed_agent(&state, &managed_agent),
        Some(crate::session::types::SessionAgentId::from(
            agent_id.as_str()
        ))
    );
    assert_eq!(
        state.agents[&agent_id].runtime_session_id(),
        Some(crate::session::types::RuntimeSessionId::from("runtime-123"))
    );
}
