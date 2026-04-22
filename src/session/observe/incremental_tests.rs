use std::collections::{HashMap, HashSet};

use crate::hooks::adapters::HookAgent;
use crate::session::service;

use super::scan::{AgentLogTailState, resolve_agent_runtime, scan_all_agents_incremental};
use super::test_support::{
    append_agent_log_lines, start_active_session, with_temp_project, write_agent_log,
};

#[test]
fn incremental_scan_skips_previously_consumed_log_bytes() {
    with_temp_project(|project| {
        let state = start_active_session(project, "sess-incremental-1", "observe test");
        let leader = state
            .agents
            .values()
            .find(|agent| agent.runtime == "claude")
            .expect("leader agent should exist");

        write_agent_log(
            project,
            HookAgent::Claude,
            "leader-session",
            "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        );

        let observed =
            service::session_status("sess-incremental-1", project).expect("load session status");
        let mut tail_states: HashMap<String, AgentLogTailState> = HashMap::new();
        let mut shared_cross_agent_editors: HashMap<String, HashSet<String>> = HashMap::new();

        let first_issues = scan_all_agents_incremental(
            &observed,
            "sess-incremental-1",
            project,
            &mut tail_states,
            &mut shared_cross_agent_editors,
        )
        .expect("scan new log content");
        assert_eq!(first_issues.len(), 1);
        let first_offset = tail_states
            .get(&leader.agent_id)
            .expect("tail state should be recorded")
            .offset;

        let second_issues = scan_all_agents_incremental(
            &observed,
            "sess-incremental-1",
            project,
            &mut tail_states,
            &mut shared_cross_agent_editors,
        )
        .expect("skip already scanned bytes");

        assert!(
            second_issues.is_empty(),
            "second incremental scan should not reread old log content",
        );
        assert_eq!(
            tail_states
                .get(&leader.agent_id)
                .expect("tail state should remain present")
                .offset,
            first_offset,
            "cursor should stay at the previous end of file when nothing new was appended",
        );
    });
}

#[test]
fn incremental_scan_detects_appended_log_lines() {
    with_temp_project(|project| {
        let state = start_active_session(project, "sess-incremental-2", "observe test");
        let leader = state
            .agents
            .values()
            .find(|agent| agent.runtime == "claude")
            .expect("leader agent should exist");

        write_agent_log(
            project,
            HookAgent::Claude,
            "leader-session",
            "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        );

        let observed =
            service::session_status("sess-incremental-2", project).expect("load session status");
        let mut tail_states: HashMap<String, AgentLogTailState> = HashMap::new();
        let mut shared_cross_agent_editors: HashMap<String, HashSet<String>> = HashMap::new();

        let first_issues = scan_all_agents_incremental(
            &observed,
            "sess-incremental-2",
            project,
            &mut tail_states,
            &mut shared_cross_agent_editors,
        )
        .expect("scan initial log content");
        assert_eq!(first_issues.len(), 1);
        let first_offset = tail_states
            .get(&leader.agent_id)
            .expect("tail state should be recorded")
            .offset;

        append_agent_log_lines(
            project,
            HookAgent::Claude,
            "leader-session",
            &[serde_json::json!({
                "timestamp": "2026-03-28T12:00:01Z",
                "message": {
                    "role": "assistant",
                    "content": "The bootstrap is missing the KUMA_MULTIZONE environment variable",
                }
            })],
        );

        let second_issues = scan_all_agents_incremental(
            &observed,
            "sess-incremental-2",
            project,
            &mut tail_states,
            &mut shared_cross_agent_editors,
        )
        .expect("scan appended log content");

        assert_eq!(second_issues.len(), 1);
        assert!(
            tail_states
                .get(&leader.agent_id)
                .expect("tail state should remain present")
                .offset
                > first_offset,
            "cursor should advance after new bytes are appended",
        );
    });
}

#[test]
fn runtime_resolution_accepts_vibe_and_opencode() {
    let vibe_runtime = resolve_agent_runtime("vibe").expect("vibe runtime");
    let opencode_runtime = resolve_agent_runtime("opencode").expect("opencode runtime");

    assert_eq!(vibe_runtime.name(), "vibe");
    assert_eq!(opencode_runtime.name(), "opencode");
}
