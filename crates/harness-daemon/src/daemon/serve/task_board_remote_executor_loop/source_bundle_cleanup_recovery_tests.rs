use super::*;

use crate::task_board::remote_wire::wire::RemoteWorkOwnerBinding;
use crate::workspace::worktree::WorktreeController;
use harness_daemon_db_queries::{
    AsyncAgentWorkingCopyQueries, WorkspaceManagedAgentKind, WorkspaceMemberRegistration,
};

#[tokio::test]
async fn workspace_prior_phase_cleanup_recovers_after_files_were_removed_before_marker() {
    let data = tempfile::tempdir().expect("create isolated data root");
    let data_path = data
        .path()
        .canonicalize()
        .expect("canonicalize isolated data root")
        .to_string_lossy()
        .into_owned();
    Box::pin(temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(data_path.as_str())),
            ("CLAUDE_SESSION_ID", Some("remote-workspace-cleanup-replay-test")),
        ],
        async {
            let source = BundleSource::new();
            let fixture = remote_executor_fixture(1).await;
            configure_executor(&fixture, source.repository.path()).await;
            let (offer, bundle_sha256) = workspace_owned_bundle_offer(&fixture.request, &source);
            upload_bundle(&fixture, &offer, &source.bytes).await;
            let (assignment, authority) =
                Box::pin(claim_with_start_authority(&fixture, &offer)).await;
            let identity = remote_executor_identity(&assignment).expect("executor identity");
            let workspace = super::super::super::source::prepare_remote_workspace(
                &fixture.db,
                &assignment,
                &offer,
                &identity,
                true,
            )
            .await
            .expect("prepare workspace-owned prior-phase source");
            let copy = fixture
                .db
                .load_agent_working_copy(&identity.working_copy_id)
                .await
                .expect("load workspace before simulated crash")
                .expect("workspace working copy");
            let import_ref = format!(
                "refs/harness/task-board/imports/{}/{bundle_sha256}",
                offer.request_sha256
            );
            assert!(git_ref_exists(source.repository.path(), &import_ref));

            let unknown = stop_workspace_unadopted_to_unknown(
                &fixture,
                &assignment,
                &authority,
                workspace.path(),
                &copy.workspace_id,
            )
            .await;
            settle_unknown(&fixture.db, &unknown).await;
            super::super::super::source_bundle::cleanup_prior_phase_import_ref(
                &unknown,
                &identity,
                Some(workspace.path()),
            )
            .await
            .expect("remove import ref before simulated crash");
            fixture
                .db
                .release_agent_working_copy(&copy.working_copy_id, "simulated cleanup crash")
                .await
                .expect("release workspace before simulated crash");
            let layout = crate::daemon::service::workspace_checkout::recorded_layout(
                &copy.project_name,
                &copy.working_copy_id,
            );
            WorktreeController::destroy(source.repository.path(), &layout)
                .expect("destroy workspace before simulated crash");
            assert!(!workspace.path().exists());
            assert!(!git_ref_exists(source.repository.path(), &import_ref));

            super::super::super::reconcile_remote_executor_assignment(
                &super::super::super::disabled_tests::executor_state(
                    &fixture.db,
                    "restarted-instance",
                ),
                &fixture.db,
                &unknown.assignment_id,
            )
            .await
            .expect("finish workspace cleanup after restart");
            let cleaned = fixture
                .db
                .task_board_remote_assignment(&unknown.assignment_id)
                .await
                .expect("load replayed workspace cleanup")
                .expect("workspace cleanup assignment");
            assert!(cleaned.cleanup_completed_at.is_some());
        },
    ))
    .await;
}

async fn stop_workspace_unadopted_to_unknown(
    fixture: &RemoteExecutorFixture,
    assignment: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    workspace: &Path,
    workspace_id: &str,
) -> TaskBoardRemoteAssignmentRecord {
    let permit = fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(authority, workspace, STARTED_AT)
        .await
        .expect("claim exact workspace Start I/O permit")
        .expect_acquired("workspace Start I/O remains permitted");
    let invalid = invalid_run(assignment, authority, workspace);
    fixture
        .db
        .save_codex_run(&invalid)
        .await
        .expect("persist stopped workspace executor run");
    let offer = assignment.require_offer().expect("strict workspace offer");
    let owner = offer.work_owner.as_ref().expect("workspace owner");
    fixture
        .db
        .register_workspace_managed_member(&WorkspaceMemberRegistration {
            workspace_id: workspace_id.to_string(),
            kind: WorkspaceManagedAgentKind::Codex,
            managed_agent_id: authority.identity.run_id.clone(),
            runtime_kind: offer.launch.runtime.clone(),
            display_name: offer.launch.display_name.clone(),
            assignment_id: Some(owner.work_item_id.clone()),
        })
        .await
        .expect("bind stopped executor to workspace");
    let persisted = fixture
        .db
        .task_board_remote_executor_run(offer, &authority.identity.run_id)
        .await
        .expect("load bound stopped workspace run")
        .expect("bound stopped workspace run");
    let pending = fixture
        .db
        .claim_task_board_remote_executor_stop_pending(
            &TaskBoardRemoteExecutorStopAuthority::Start(Box::new(permit)),
            &persisted,
            TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
            UNKNOWN_AT,
        )
        .await
        .expect("claim exact workspace stop-only authority")
        .expect("workspace stop-only authority");
    let TaskBoardRemoteMutationOutcome::Updated(unknown) = fixture
        .db
        .settle_task_board_remote_executor_stop_pending(&pending, UNKNOWN_AT)
        .await
        .expect("settle exact stopped workspace run")
    else {
        panic!("stopped workspace run did not become unknown");
    };
    unknown
}

fn workspace_owned_bundle_offer(
    template: &RemoteOfferRequest,
    source: &BundleSource,
) -> (RemoteOfferRequest, String) {
    let (mut offer, bundle_sha256) = bundle_offer(template, source);
    offer.work_owner = Some(RemoteWorkOwnerBinding {
        source_daemon_id: "source-daemon".into(),
        workspace_id: "source-workspace".into(),
        working_copy_id: "source-copy".into(),
        work_item_id: "source-work-item".into(),
        managed_agent_id: offer.binding.idempotency_key.clone(),
    });
    offer.request_sha256.clear();
    (
        offer.seal().expect("seal workspace-owned bundle offer"),
        bundle_sha256,
    )
}
