use crate::hooks::adapters::HookAgent;
use crate::observe::load_observer_state;
use crate::observe::types::IssueCode;
use crate::session::service;
use crate::session::types::{SessionRole, TaskSeverity};
use crate::workspace::project_context_dir;

use super::once::execute_session_observe;
use super::scan::scan_all_agents;
use super::support::{create_work_items_for_issues, persist_observer_snapshot};
use super::test_support::{
    infrastructure_issue, start_active_session, with_temp_project, write_agent_log,
    write_agent_log_lines,
};

#[test]
fn observe_scans_logs_via_runtime_session_id() {
    with_temp_project(|project| {
        let state = start_active_session(
            project,
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            "observe test",
        );

        temp_env::with_vars(
            [(
                "CODEX_SESSION_ID",
                Some("008d974f-c6a9-53e5-a62e-d331367c449a"),
            )],
            || {
                let joined = service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join codex worker");
                let worker = joined
                    .agents
                    .values()
                    .find(|agent| agent.runtime == "codex")
                    .expect("codex worker should be registered");
                assert_ne!(worker.agent_id, "008d974f-c6a9-53e5-a62e-d331367c449a");
            },
        );

        write_agent_log(
            project,
            HookAgent::Codex,
            "008d974f-c6a9-53e5-a62e-d331367c449a",
            "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        );

        let state = service::session_status("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc", project)
            .expect("load session status");
        let issues = scan_all_agents(&state, "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc", project)
            .expect("scan session logs");

        assert!(
            !issues.is_empty(),
            "expected observe to find transcript issues"
        );
    });
}

#[test]
fn observe_scans_logs_via_legacy_session_fallback() {
    with_temp_project(|project| {
        let state = start_active_session(
            project,
            "319dd219-642f-546f-9d99-3554bf39d6d6",
            "observe test",
        );

        let joined = service::join_session(
            &state.session_id,
            SessionRole::Worker,
            "codex",
            &[],
            None,
            project,
            None,
        )
        .expect("join codex worker");
        let worker = joined
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("codex worker should be registered");
        let worker_id = worker.agent_id.clone();
        let layout = crate::session::storage::layout_from_project_dir(project, &state.session_id)
            .expect("layout");
        crate::session::storage::update_state(&layout, |state| {
            state
                .agents
                .get_mut(&worker_id)
                .expect("legacy worker should exist")
                .agent_session_id = None;
            Ok(())
        })
        .expect("clear worker runtime session id for legacy fixture");

        write_agent_log(
            project,
            HookAgent::Codex,
            &state.session_id,
            "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        );

        let state = service::session_status("319dd219-642f-546f-9d99-3554bf39d6d6", project)
            .expect("load session status");
        let worker = state
            .agents
            .get(&worker_id)
            .expect("legacy worker should be present");
        assert!(worker.agent_session_id.is_none());
        let issues = scan_all_agents(&state, "319dd219-642f-546f-9d99-3554bf39d6d6", project)
            .expect("scan legacy session logs");

        assert!(
            !issues.is_empty(),
            "expected observe to find transcript issues for legacy sessions"
        );
    });
}

#[test]
fn observe_without_actor_stays_read_only() {
    with_temp_project(|project| {
        start_active_session(
            project,
            "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
            "observe test",
        );
        write_agent_log(
            project,
            HookAgent::Claude,
            "77d13b08-1651-541b-a3fc-26cab59e0aea",
            "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        );

        let exit_code =
            execute_session_observe("00b4a39f-719e-5418-abe8-eb3ab6ea614d", project, true, None)
                .expect("observe succeeds");

        assert_eq!(exit_code, 1);
        assert!(
            service::list_tasks("00b4a39f-719e-5418-abe8-eb3ab6ea614d", None, project)
                .expect("list tasks")
                .is_empty(),
            "observe without --actor must not create tasks",
        );
    });
}

#[test]
fn observe_scans_canonical_tool_result_tracebacks() {
    with_temp_project(|project| {
        let state = start_active_session(
            project,
            "77edf66e-18db-5bb3-b48f-e4605c940a61",
            "observe test",
        );
        let leader_runtime_session_id = state
            .agents
            .values()
            .find(|agent| agent.role == SessionRole::Leader)
            .and_then(|agent| agent.agent_session_id.clone())
            .expect("leader should have a runtime session id");

        write_agent_log_lines(
            project,
            HookAgent::Claude,
            &leader_runtime_session_id,
            &[
                serde_json::json!({
                    "timestamp": "2026-03-28T12:00:00Z",
                    "message": {
                        "role": "assistant",
                        "content": [{
                            "type": "tool_use",
                            "id": "heuristic-python-traceback",
                            "name": "Bash",
                            "input": { "command": "python foo.py" }
                        }]
                    }
                }),
                serde_json::json!({
                    "timestamp": "2026-03-28T12:00:00Z",
                    "message": {
                        "role": "user",
                        "content": [{
                            "type": "tool_result",
                            "tool_use_id": "heuristic-python-traceback",
                            "tool_name": "Bash",
                            "is_error": true,
                            "content": [{
                                "type": "text",
                                "text": "Traceback (most recent call last):\n  File \"foo.py\", line 1, in <module>\n  ValueError: bad"
                            }]
                        }]
                    }
                }),
            ],
        );

        let reloaded =
            service::session_status(&state.session_id, project).expect("load session status");
        let issues =
            scan_all_agents(&reloaded, &state.session_id, project).expect("scan session logs");

        assert!(
            issues
                .iter()
                .any(|issue| issue.code == IssueCode::PythonTracebackOutput),
            "expected observe to find canonical tool_result traceback issues"
        );
    });
}

#[test]
fn observe_keeps_distinct_issue_ids_when_titles_match() {
    with_temp_project(|project| {
        let state = start_active_session(
            project,
            "86454ce7-8ac9-5f4f-ba72-8128a78e3a84",
            "observe test",
        );
        let leader_id = state.leader_id.clone().expect("leader id");
        let issues = vec![
            infrastructure_issue("fingerprint-a"),
            infrastructure_issue("fingerprint-b"),
        ];

        create_work_items_for_issues(
            &issues,
            "86454ce7-8ac9-5f4f-ba72-8128a78e3a84",
            &state,
            project,
            Some(&leader_id),
        )
        .expect("create deduplicated tasks");

        let tasks = service::list_tasks("86454ce7-8ac9-5f4f-ba72-8128a78e3a84", None, project)
            .expect("list tasks");
        assert_eq!(tasks.len(), 2);
        assert_eq!(
            tasks[0].severity,
            TaskSeverity::Critical,
            "task severity should follow the issue severity",
        );
    });
}

#[test]
fn observe_deduplicates_existing_issue_id_even_when_title_changes() {
    with_temp_project(|project| {
        let state = start_active_session(
            project,
            "fbbde0b1-87ab-53c2-b7f0-9b9a3ecccb49",
            "observe test",
        );
        let leader_id = state.leader_id.clone().expect("leader id");
        let issue = infrastructure_issue("fingerprint-a");

        create_work_items_for_issues(
            std::slice::from_ref(&issue),
            "fbbde0b1-87ab-53c2-b7f0-9b9a3ecccb49",
            &state,
            project,
            Some(&leader_id),
        )
        .expect("create initial task");

        let reloaded = service::session_status("fbbde0b1-87ab-53c2-b7f0-9b9a3ecccb49", project)
            .expect("reload session");
        let mut updated_issue = issue.clone();
        updated_issue.summary = "Harness infrastructure issue renamed after retry".to_string();

        create_work_items_for_issues(
            std::slice::from_ref(&updated_issue),
            "fbbde0b1-87ab-53c2-b7f0-9b9a3ecccb49",
            &reloaded,
            project,
            Some(&leader_id),
        )
        .expect("skip duplicate issue");

        let tasks = service::list_tasks("fbbde0b1-87ab-53c2-b7f0-9b9a3ecccb49", None, project)
            .expect("list tasks");
        assert_eq!(tasks.len(), 1);
        assert_eq!(
            tasks[0].observe_issue_id.as_deref(),
            Some(issue.id.as_str())
        );
    });
}

#[test]
fn observer_snapshot_skips_repeated_empty_scans() {
    with_temp_project(|project| {
        let state = start_active_session(
            project,
            "d6777e46-f714-508d-ac93-5b29e1a7ae02",
            "observe empty",
        );
        let observe_id = state.observe_id.as_deref().expect("observe id");

        let first_written =
            persist_observer_snapshot(&state, project, &[]).expect("persist initial scan");
        let second_written =
            persist_observer_snapshot(&state, project, &[]).expect("skip unchanged scan");
        let observer =
            load_observer_state(&project_context_dir(project), observe_id, &state.session_id)
                .expect("load observer state");

        assert!(first_written);
        assert!(!second_written);
        assert_eq!(observer.state_version, 1);
    });
}
