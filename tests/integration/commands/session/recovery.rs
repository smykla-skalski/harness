use harness::session::service;
use harness::session::types::{SessionRole, SessionStatus};

use super::with_session_test_env;

#[test]
fn recover_leader_builds_managed_tui_request_from_policy_preset() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_session_test_env(tmp.path(), "recover-leader", || {
        let project = tmp.path().join("project");
        let state = service::start_session_with_policy(
            "recover leader",
            "",
            &project,
            Some("claude"),
            Some("recover-1"),
            Some("swarm-default"),
        )
        .expect("start");
        let leader_id = state.leader_id.clone().expect("leader");

        service::leave_session("recover-1", &leader_id, &project).expect("leave");

        let updated = service::session_status("recover-1", &project).expect("status");
        assert_eq!(updated.status, SessionStatus::LeaderlessDegraded);

        let request =
            service::build_recovery_tui_request("recover-1", "swarm-default", "codex", &project)
                .expect("build recovery request");
        assert_eq!(request.runtime, "codex");
        assert_eq!(request.role, SessionRole::Leader);
        assert_eq!(
            request.capabilities,
            vec!["policy-preset:swarm-default".to_string()]
        );
        assert_eq!(
            request.project_dir.as_deref(),
            Some(project.to_string_lossy().as_ref())
        );
    });
}
