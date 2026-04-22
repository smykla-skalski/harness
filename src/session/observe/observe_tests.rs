use crate::hooks::adapters::HookAgent;
use crate::session::service;
use crate::session::types::{SessionRole, TaskSeverity};

use super::once::execute_session_observe;
use super::scan::scan_all_agents;
use super::support::create_work_items_for_issues;
use super::test_support::{
    infrastructure_issue, start_active_session, with_temp_project, write_agent_log,
};

#[test]
fn observe_scans_logs_via_runtime_session_id() {
    with_temp_project(|project| {
        let state = start_active_session(project, "sess-1", "observe test");

        temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
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
            assert_ne!(worker.agent_id, "worker-session");
        });

        write_agent_log(
            project,
            HookAgent::Codex,
            "worker-session",
            "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        );

        let state = service::session_status("sess-1", project).expect("load session status");
        let issues = scan_all_agents(&state, "sess-1", project).expect("scan session logs");

        assert!(
            !issues.is_empty(),
            "expected observe to find transcript issues"
        );
    });
}

#[test]
fn observe_scans_logs_via_legacy_session_fallback() {
    with_temp_project(|project| {
        let state = start_active_session(project, "sess-legacy", "observe test");

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

        let state = service::session_status("sess-legacy", project).expect("load session status");
        let worker = state
            .agents
            .get(&worker_id)
            .expect("legacy worker should be present");
        assert!(worker.agent_session_id.is_none());
        let issues =
            scan_all_agents(&state, "sess-legacy", project).expect("scan legacy session logs");

        assert!(
            !issues.is_empty(),
            "expected observe to find transcript issues for legacy sessions"
        );
    });
}

#[test]
fn observe_without_actor_stays_read_only() {
    with_temp_project(|project| {
        start_active_session(project, "sess-2", "observe test");
        write_agent_log(
            project,
            HookAgent::Claude,
            "leader-session",
            "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        );

        let exit_code =
            execute_session_observe("sess-2", project, true, None).expect("observe succeeds");

        assert_eq!(exit_code, 1);
        assert!(
            service::list_tasks("sess-2", None, project)
                .expect("list tasks")
                .is_empty(),
            "observe without --actor must not create tasks",
        );
    });
}

#[test]
fn observe_keeps_distinct_issue_ids_when_titles_match() {
    with_temp_project(|project| {
        let state = start_active_session(project, "sess-3", "observe test");
        let leader_id = state.leader_id.clone().expect("leader id");
        let issues = vec![
            infrastructure_issue("fingerprint-a"),
            infrastructure_issue("fingerprint-b"),
        ];

        create_work_items_for_issues(&issues, "sess-3", &state, project, Some(&leader_id))
            .expect("create deduplicated tasks");

        let tasks = service::list_tasks("sess-3", None, project).expect("list tasks");
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
        let state = start_active_session(project, "sess-4", "observe test");
        let leader_id = state.leader_id.clone().expect("leader id");
        let issue = infrastructure_issue("fingerprint-a");

        create_work_items_for_issues(
            std::slice::from_ref(&issue),
            "sess-4",
            &state,
            project,
            Some(&leader_id),
        )
        .expect("create initial task");

        let reloaded = service::session_status("sess-4", project).expect("reload session");
        let mut updated_issue = issue.clone();
        updated_issue.summary = "Harness infrastructure issue renamed after retry".to_string();

        create_work_items_for_issues(
            std::slice::from_ref(&updated_issue),
            "sess-4",
            &reloaded,
            project,
            Some(&leader_id),
        )
        .expect("skip duplicate issue");

        let tasks = service::list_tasks("sess-4", None, project).expect("list tasks");
        assert_eq!(tasks.len(), 1);
        assert_eq!(
            tasks[0].observe_issue_id.as_deref(),
            Some(issue.id.as_str())
        );
    });
}
