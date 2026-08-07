use super::*;

#[tokio::test]
async fn incomplete_worktree_metadata_blocks_workspace_creation() {
    let fixture = Fixture::new().await;
    let project = fixture.worktree_project("project-incomplete-worktree");
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-incomplete-worktree",
        "active",
        NOW,
        false,
    )
    .await;
    query(
        "UPDATE projects
         SET project_dir = NULL, repository_root = NULL, worktree_name = NULL
         WHERE project_id = ?1",
    )
    .bind(&project.id)
    .execute(fixture.db.pool())
    .await
    .expect("remove worktree identity metadata");

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reject incomplete worktree metadata");
    assert!(response.workspaces.is_empty());
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::MalformedCandidate
    );
    assert_eq!(workspace_count(fixture.db.pool()).await, 0);
}

#[tokio::test]
async fn unrelated_checkout_cannot_replace_recorded_worktree() {
    let fixture = Fixture::new().await;
    let project = fixture.worktree_project("project-unrelated");
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-unrelated",
        "active",
        NOW,
        false,
    )
    .await;
    let first = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create worktree workspace");
    assert_eq!(
        first.workspaces[0].availability,
        AgentWorkspaceAvailability::Available
    );

    std::fs::remove_dir_all(&project.checkout_root).expect("remove recorded worktree");
    harness_testkit::init_git_repo_with_seed(&project.checkout_root);

    let replaced = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile unrelated replacement");
    assert_eq!(
        replaced.workspaces[0].availability,
        AgentWorkspaceAvailability::MissingWorktree
    );
}

#[tokio::test]
async fn regular_file_is_not_an_available_checkout() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-file", false);
    std::fs::write(&project.checkout_root, "not a checkout").expect("create regular file");
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-file",
        "active",
        NOW,
        false,
    )
    .await;

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile regular file");
    assert_eq!(
        response.workspaces[0].availability,
        AgentWorkspaceAvailability::MissingWorktree
    );
}

#[tokio::test]
async fn ownerless_workspace_availability_refreshes_both_directions() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-ownerless-availability", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-ownerless-availability",
        "active",
        NOW,
        false,
    )
    .await;
    let workspace_id = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace")
        .workspaces[0]
        .workspace_id
        .clone();
    fixture.reconcile_activity(&workspace_id).await;

    std::fs::remove_dir_all(&project.checkout_root).expect("remove checkout");
    query("DELETE FROM sessions WHERE session_id = 'session-ownerless-availability'")
        .execute(fixture.db.pool())
        .await
        .expect("delete legacy Session");
    let missing = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("refresh missing ownerless checkout");
    assert_eq!(
        missing.workspaces[0].availability,
        AgentWorkspaceAvailability::MissingWorktree
    );
    assert_eq!(
        missing.workspaces[0].orchestration_authority,
        AgentWorkspaceOrchestrationAuthority::NoOwner
    );

    std::fs::create_dir_all(&project.checkout_root).expect("restore exact checkout");
    let restored = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("refresh restored ownerless checkout");
    assert_eq!(
        restored.workspaces[0].availability,
        AgentWorkspaceAvailability::Available
    );
}
