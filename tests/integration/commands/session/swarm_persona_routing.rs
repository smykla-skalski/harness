//! Integration coverage for persona-aware worker routing through the
//! queued-reassignment path. When a task's `suggested_persona` is set,
//! the queue advance step must pick a matching worker over a bare one
//! even if the bare agent id sorts alphabetically first.

use harness::daemon::protocol::TaskDropTarget;
use harness::session::service;
use harness::session::types::{SessionRole, TaskQueuePolicy, TaskSeverity};

use super::with_session_test_env;

#[test]
fn persona_matching_worker_picks_up_reassignable_task_over_bare_agent() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-persona-routing", || {
        let project = tmp.path().join("project");
        service::start_session_with_policy(
            "",
            "persona routing",
            &project,
            Some("persona-rt"),
            Some("swarm-default"),
        )
        .unwrap();
        let leader_state = service::join_session(
            "persona-rt",
            SessionRole::Leader,
            "claude",
            &[],
            None,
            &project,
            None,
        )
        .unwrap();
        let leader_id = leader_state.leader_id.clone().unwrap();

        // Alphabetically-first agent (bare, no persona).
        let bare = temp_env::with_var("CODEX_SESSION_ID", Some("bare-worker"), || {
            service::join_session(
                "persona-rt",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                &project,
                None,
            )
            .unwrap()
        });
        let bare_id = bare
            .agents
            .values()
            .find(|agent| agent.runtime == "codex" && agent.persona.is_none())
            .unwrap()
            .agent_id
            .clone();

        // Persona-matching agent joins AFTER; agent id sorts later lexically.
        let persona = temp_env::with_var("GEMINI_SESSION_ID", Some("persona-worker"), || {
            service::join_session(
                "persona-rt",
                SessionRole::Worker,
                "gemini",
                &[],
                None,
                &project,
                Some("test-writer"),
            )
            .unwrap()
        });
        let persona_id = persona
            .agents
            .values()
            .find(|agent| agent.runtime == "gemini")
            .unwrap()
            .agent_id
            .clone();

        // Keep the bare worker busy so the persona-hinted task sits queued
        // with `ReassignWhenFree`. The persona-matching worker stays free so
        // that when the queue advances, both workers appear as free
        // candidates and ranking must pick the persona match.
        let first = service::create_task(
            "persona-rt",
            "first",
            None,
            TaskSeverity::Medium,
            &leader_id,
            &project,
        )
        .unwrap();
        service::assign_task("persona-rt", &first.task_id, &bare_id, &leader_id, &project).unwrap();
        service::update_task(
            "persona-rt",
            &first.task_id,
            harness::session::types::TaskStatus::InProgress,
            None,
            &bare_id,
            &project,
        )
        .unwrap();

        let persona_task = service::create_task(
            "persona-rt",
            "persona-only work",
            None,
            TaskSeverity::Medium,
            &leader_id,
            &project,
        )
        .unwrap();
        service::drop_task(
            "persona-rt",
            &persona_task.task_id,
            &TaskDropTarget::Agent {
                agent_id: bare_id.clone(),
            },
            TaskQueuePolicy::ReassignWhenFree,
            &leader_id,
            &project,
        )
        .unwrap();

        // Stamp the persona hint directly on the queued task — in production
        // this arrives via submit_for_review_with_persona; for routing
        // coverage we bypass the review lifecycle and set the field.
        let layout = harness::session::storage::layout_from_project_dir(&project, "persona-rt")
            .unwrap();
        let state_before = service::session_status("persona-rt", &project).unwrap();
        let mut patched = state_before.clone();
        patched
            .tasks
            .get_mut(&persona_task.task_id)
            .unwrap()
            .suggested_persona = Some("test-writer".to_string());
        std::fs::write(
            layout.state_file(),
            serde_json::to_vec_pretty(&patched).unwrap(),
        )
        .unwrap();

        // Bare finishes → queue advance runs with both workers free. Ranking
        // must prefer the persona-matching worker.
        service::update_task(
            "persona-rt",
            &first.task_id,
            harness::session::types::TaskStatus::Done,
            None,
            &bare_id,
            &project,
        )
        .unwrap();

        let state = service::session_status("persona-rt", &project).unwrap();
        let task = state.tasks.get(&persona_task.task_id).unwrap();
        assert_eq!(
            task.assigned_to.as_deref(),
            Some(persona_id.as_str()),
            "persona-matching worker must win queue reassignment over bare agent; got {:?}",
            task.assigned_to
        );
    });
}
