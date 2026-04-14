use super::*;

#[test]
fn join_session_with_persona_stores_resolved_persona() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-persona-resolve", || {
        let project = tmp.path().join("project");

        service::start_session(
            "persona test",
            "",
            &project,
            Some("claude"),
            Some("persona-1"),
        )
        .unwrap();

        let state = service::join_session(
            "persona-1",
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

        service::start_session(
            "persona test",
            "",
            &project,
            Some("claude"),
            Some("persona-2"),
        )
        .unwrap();

        let state = service::join_session(
            "persona-2",
            SessionRole::Worker,
            "codex",
            &[],
            None,
            &project,
            Some("nonexistent-persona"),
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

        service::start_session(
            "persona test",
            "",
            &project,
            Some("claude"),
            Some("persona-3"),
        )
        .unwrap();

        let state = service::join_session(
            "persona-3",
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
