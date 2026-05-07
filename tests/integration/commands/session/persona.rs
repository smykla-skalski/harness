use super::*;

#[test]
fn join_session_with_persona_stores_resolved_persona() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-persona-resolve", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("persona-1");

        service::start_session("", "persona test", &project, Some(&session_id)).unwrap();

        let state = service::join_session(
            &session_id,
            SessionRole::Worker,
            "codex",
            &[],
            None,
            &project,
            Some("code-reviewer"),
        )
        .unwrap();

        let worker = state
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("codex worker should exist");
        let persona = worker.persona.as_ref().expect("persona should be set");
        assert_eq!(persona.identifier, "code-reviewer");
        assert_eq!(persona.name, "Code Reviewer");
    });
}

#[test]
fn join_session_with_unknown_persona_stores_none() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-persona-unknown", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("persona-2");

        service::start_session("", "persona test", &project, Some(&session_id)).unwrap();

        let state = service::join_session(
            &session_id,
            SessionRole::Worker,
            "codex",
            &[],
            None,
            &project,
            Some("418cf829-6691-5fc0-92b1-8e5013efa2cb-persona"),
        )
        .unwrap();

        let worker = state
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("codex worker should exist");
        assert!(
            worker.persona.is_none(),
            "unknown persona should resolve to None"
        );
    });
}

#[test]
fn join_session_without_persona_backward_compat() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-persona-none", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("persona-3");

        service::start_session("", "persona test", &project, Some(&session_id)).unwrap();

        let state = service::join_session(
            &session_id,
            SessionRole::Worker,
            "codex",
            &[],
            None,
            &project,
            None,
        )
        .unwrap();

        let worker = state
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("codex worker should exist");
        assert!(
            worker.persona.is_none(),
            "no persona passed should mean None"
        );
    });
}
