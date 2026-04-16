use super::*;

#[test]
fn join_session_direct_rejects_leader_role() {
    with_temp_project(|project| {
        let db = setup_db_with_project(project);
        start_direct_session(
            &db,
            project,
            "leader-join-denied",
            "leader join denied",
            "daemon joins cannot claim leader",
            None,
        );
        let error = join_direct_codex(
            &db,
            project,
            "leader-join-denied",
            "leader-join-worker",
            SessionRole::Leader,
            None,
            Some("spoofed leader"),
        )
        .expect_err("leader join should be rejected");
        assert_eq!(error.code(), "KSRCLI092");
        assert!(error.message().contains("leader"));
    });
}
