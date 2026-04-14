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
    )
    .expect("second join");

    assert_eq!(first, second, "same marker should return same agent_id");
    // Only the leader + one worker, no duplicate
    assert_eq!(state.agents.len(), 2);
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
    )
    .expect("second join");

    assert_ne!(
        first, second,
        "different markers should create distinct agents"
    );
    // Leader + two distinct workers
    assert_eq!(state.agents.len(), 3);
}
