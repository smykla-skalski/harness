use super::*;

#[tokio::test]
async fn retiring_one_daemon_does_not_bless_another_daemons_corruption() {
    const OTHER_DAEMON_ID: &str = "daemon-other";

    let fixture = Fixture::new().await;
    let project = fixture.project("project-daemon-scope", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-daemon-scope",
        "active",
        NOW,
        false,
    )
    .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create first daemon workspace");
    fixture
        .db
        .reconcile_agent_workspaces(OTHER_DAEMON_ID)
        .await
        .expect("create second daemon workspace");
    query(
        "UPDATE agent_workspaces
         SET context_root = '/tampered/other-daemon'
         WHERE daemon_id = ?1",
    )
    .bind(OTHER_DAEMON_ID)
    .execute(fixture.db.pool())
    .await
    .expect("tamper second daemon workspace");
    query("DELETE FROM sessions WHERE session_id = 'session-daemon-scope'")
        .execute(fixture.db.pool())
        .await
        .expect("delete legacy Session");

    let first_daemon = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("retire first daemon owner");
    assert_eq!(
        first_daemon.workspaces[0].orchestration_authority,
        AgentWorkspaceOrchestrationAuthority::NoOwner
    );
    let other_authority = query_scalar::<_, String>(
        "SELECT orchestration_authority FROM agent_workspaces WHERE daemon_id = ?1",
    )
    .bind(OTHER_DAEMON_ID)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load other daemon authority");
    assert_eq!(other_authority, "legacy_session");
    let queued = query_scalar::<_, i64>("SELECT COUNT(*) FROM agent_workspace_reconcile_queue")
        .fetch_one(fixture.db.pool())
        .await
        .expect("count pending daemon retirement");
    assert_eq!(queued, 1);

    let other_daemon = fixture
        .db
        .reconcile_agent_workspaces(OTHER_DAEMON_ID)
        .await
        .expect("detect other daemon corruption");
    assert!(other_daemon.workspaces.is_empty());
    assert_eq!(
        other_daemon.conflicts[0].kind,
        AgentWorkspaceConflictKind::SourceDisagreement
    );
}

#[tokio::test]
async fn runtime_recovery_write_updates_shadow_without_a_session_write() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-runtime-recovery", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-runtime-recovery",
        "active",
        NOW,
        true,
    )
    .await;
    let first = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create active workspace");
    let first_manifest = first.workspaces[0].provenance.manifest_digest.clone();

    query(
        "UPDATE agent_turn_runs
         SET status = 'failed', updated_at = '2026-08-06T10:01:00Z'
         WHERE session_id = 'session-runtime-recovery'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("settle interrupted turn");

    let recovered = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile runtime recovery");
    assert!(recovered.conflicts.is_empty());
    assert_ne!(
        recovered.workspaces[0].provenance.manifest_digest,
        first_manifest
    );
    assert_eq!(workspace_count(fixture.db.pool()).await, 1);
}

#[tokio::test]
async fn no_op_session_write_does_not_authorize_shadow_disagreement() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-no-op", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-no-op",
        "active",
        NOW,
        false,
    )
    .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace");
    query("UPDATE agent_workspaces SET manifest_digest = 'tampered'")
        .execute(fixture.db.pool())
        .await
        .expect("tamper shadow workspace");
    query("UPDATE sessions SET state_json = state_json WHERE session_id = 'session-no-op'")
        .execute(fixture.db.pool())
        .await
        .expect("queue no-op Session write");

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("detect shadow disagreement");
    assert!(response.workspaces.is_empty());
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::SourceDisagreement
    );
    let manifest = query_scalar::<_, String>("SELECT manifest_digest FROM agent_workspaces")
        .fetch_one(fixture.db.pool())
        .await
        .expect("load preserved shadow");
    assert_eq!(manifest, "tampered");
}

#[tokio::test]
async fn changed_project_identity_blocks_a_second_workspace() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-moved", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-moved",
        "active",
        NOW,
        false,
    )
    .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace");
    let moved_root = fixture.temp.path().join("moved-repository");
    std::fs::create_dir_all(&moved_root).expect("create moved repository");
    query(
        "UPDATE projects
         SET repository_root = ?2, updated_at = '2026-08-06T10:01:00Z'
         WHERE project_id = ?1",
    )
    .bind(&project.id)
    .bind(path_text(&moved_root))
    .execute(fixture.db.pool())
    .await
    .expect("change canonical project identity");

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("block identity change");
    assert!(response.workspaces.is_empty());
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::SourceDisagreement
    );
    assert_eq!(workspace_count(fixture.db.pool()).await, 1);
}

#[tokio::test]
async fn tampered_workspace_field_is_not_silently_repaired() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-field-tamper", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-field-tamper",
        "active",
        NOW,
        false,
    )
    .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace");
    query("UPDATE agent_workspaces SET context_root = '/tampered/context'")
        .execute(fixture.db.pool())
        .await
        .expect("tamper workspace field");

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("detect workspace tamper");
    assert!(response.workspaces.is_empty());
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::SourceDisagreement
    );
    let context_root = query_scalar::<_, String>("SELECT context_root FROM agent_workspaces")
        .fetch_one(fixture.db.pool())
        .await
        .expect("load preserved workspace field");
    assert_eq!(context_root, "/tampered/context");
}

#[tokio::test]
async fn tampered_provenance_is_not_silently_repaired() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-provenance-tamper", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-provenance-tamper",
        "active",
        NOW,
        false,
    )
    .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace");
    query("UPDATE agent_workspace_legacy_sessions SET lifecycle = 'ended'")
        .execute(fixture.db.pool())
        .await
        .expect("tamper workspace provenance");

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("detect provenance tamper");
    assert!(response.workspaces.is_empty());
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::SourceDisagreement
    );
    let lifecycle =
        query_scalar::<_, String>("SELECT lifecycle FROM agent_workspace_legacy_sessions")
            .fetch_one(fixture.db.pool())
            .await
            .expect("load preserved provenance");
    assert_eq!(lifecycle, "ended");
}

#[tokio::test]
async fn tampered_workspace_is_not_blessed_when_its_session_is_deleted() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-delete-tamper", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-delete-tamper",
        "active",
        NOW,
        false,
    )
    .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace");
    query("UPDATE agent_workspaces SET context_root = '/tampered/before-delete'")
        .execute(fixture.db.pool())
        .await
        .expect("tamper workspace");
    query("DELETE FROM sessions WHERE session_id = 'session-delete-tamper'")
        .execute(fixture.db.pool())
        .await
        .expect("delete legacy Session");

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reject corrupt ownerless transition");
    assert!(response.workspaces.is_empty());
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::SourceDisagreement
    );
    let authority =
        query_scalar::<_, String>("SELECT orchestration_authority FROM agent_workspaces")
            .fetch_one(fixture.db.pool())
            .await
            .expect("load preserved authority");
    assert_eq!(authority, "legacy_session");
}

#[tokio::test]
async fn tampered_ownerless_workspace_is_hidden() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-ownerless-tamper", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-ownerless-tamper",
        "active",
        NOW,
        false,
    )
    .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace");
    query("DELETE FROM sessions WHERE session_id = 'session-ownerless-tamper'")
        .execute(fixture.db.pool())
        .await
        .expect("delete legacy Session");
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("retire workspace owner");
    query("UPDATE agent_workspaces SET context_root = '/tampered/ownerless'")
        .execute(fixture.db.pool())
        .await
        .expect("tamper ownerless workspace");

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("detect ownerless tamper");
    assert!(response.workspaces.is_empty());
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::SourceDisagreement
    );
}

#[tokio::test]
async fn immutable_created_at_is_shadow_verified() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-created-at", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-created-at",
        "active",
        NOW,
        false,
    )
    .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace");
    query("UPDATE agent_workspaces SET created_at = 'tampered'")
        .execute(fixture.db.pool())
        .await
        .expect("tamper immutable timestamp");

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("detect immutable timestamp tamper");
    assert!(response.workspaces.is_empty());
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::SourceDisagreement
    );
    let created_at = query_scalar::<_, String>("SELECT created_at FROM agent_workspaces")
        .fetch_one(fixture.db.pool())
        .await
        .expect("load preserved timestamp");
    assert_eq!(created_at, "tampered");
}

#[tokio::test]
async fn noncanonical_boolean_encoding_is_shadow_verified() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-boolean-encoding", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-boolean-encoding",
        "active",
        NOW,
        false,
    )
    .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace");
    let mut connection = fixture
        .db
        .pool()
        .acquire()
        .await
        .expect("acquire tamper connection");
    query("PRAGMA ignore_check_constraints = ON")
        .execute(connection.as_mut())
        .await
        .expect("allow corruption fixture");
    query("UPDATE agent_workspaces SET is_worktree = 2")
        .execute(connection.as_mut())
        .await
        .expect("tamper boolean representation");
    query("PRAGMA ignore_check_constraints = OFF")
        .execute(connection.as_mut())
        .await
        .expect("restore constraint enforcement");
    drop(connection);

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("detect boolean representation tamper");
    assert!(response.workspaces.is_empty());
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::SourceDisagreement
    );
    let is_worktree = query_scalar::<_, i64>("SELECT is_worktree FROM agent_workspaces")
        .fetch_one(fixture.db.pool())
        .await
        .expect("load preserved boolean encoding");
    assert_eq!(is_worktree, 2);
}
