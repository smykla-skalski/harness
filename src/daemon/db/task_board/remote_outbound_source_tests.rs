use sha2::{Digest as _, Sha256};

use super::remote_assignment_model::insert_assignment_in_tx;
use super::remote_assignment_test_support::{
    DEADLINE, INSTANCE, LEASE_EXPIRES, NOW, PRINCIPAL, REPOSITORY, SOURCE_REVISION,
    executor_fixture,
};
use super::remote_offer_receipts::ensure_rejected_offer_receipt_in_tx;
use super::remote_outbound_sources::{
    persist_outbound_source_in_tx, require_outbound_source_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteOfferRequest, RemoteSourceMaterial,
    test_codex_launch,
};
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardWorkflowKind};

#[tokio::test]
async fn outbound_source_is_atomic_with_assignment_and_restart_replay() {
    let fixture = executor_fixture(1).await;
    let (offer, content) = snapshot_offer(&fixture.request);
    let mut transaction = fixture
        .db
        .begin_immediate_transaction("test outbound source insert")
        .await
        .expect("begin outbound source insert");
    insert_assignment_in_tx(
        &mut transaction,
        &offer,
        PRINCIPAL,
        NOW,
        None,
        LEASE_EXPIRES,
        DEADLINE,
        None,
        None,
        None,
    )
    .await
    .expect("insert exact outbound assignment");
    persist_outbound_source_in_tx(&mut transaction, &offer, Some(&content), NOW)
        .await
        .expect("persist exact outbound source");
    transaction
        .commit()
        .await
        .expect("commit assignment and outbound source");
    assert!(source_recovery_owns(&fixture.db, &offer).await);

    let first = fixture
        .db
        .task_board_remote_outbound_source_upload(
            &offer.binding.assignment_id,
            offer.binding.fencing_epoch,
        )
        .await
        .expect("load outbound source")
        .expect("outbound source exists");
    let reopened = AsyncDaemonDb::connect(&fixture._temp.path().join("executor.db"))
        .await
        .expect("reopen outbound source database");
    let replay = reopened
        .task_board_remote_outbound_source_upload(
            &offer.binding.assignment_id,
            offer.binding.fencing_epoch,
        )
        .await
        .expect("replay outbound source")
        .expect("outbound source survives restart");
    assert_eq!(replay, first);

    let mut transaction = reopened
        .begin_immediate_transaction("test outbound source replay")
        .await
        .expect("begin outbound replay");
    require_outbound_source_in_tx(&mut transaction, &offer, Some(&content))
        .await
        .expect("exact outbound source replay");
    assert!(
        require_outbound_source_in_tx(&mut transaction, &offer, Some(b"different"))
            .await
            .is_err()
    );
    ensure_rejected_offer_receipt_in_tx(
        &mut transaction,
        &offer,
        PRINCIPAL,
        "executor_unavailable",
        NOW,
    )
    .await
    .expect("persist conclusive offer rejection");
    transaction
        .commit()
        .await
        .expect("commit conclusive offer receipt");
    assert!(!source_recovery_owns(&reopened, &offer).await);
}

#[tokio::test]
async fn missing_outbound_bytes_roll_back_the_assignment_generation() {
    let fixture = executor_fixture(1).await;
    let (offer, _) = snapshot_offer(&fixture.request);
    let mut transaction = fixture
        .db
        .begin_immediate_transaction("test missing outbound source")
        .await
        .expect("begin missing outbound source");
    insert_assignment_in_tx(
        &mut transaction,
        &offer,
        PRINCIPAL,
        NOW,
        None,
        LEASE_EXPIRES,
        DEADLINE,
        None,
        None,
        None,
    )
    .await
    .expect("insert provisional assignment");
    assert!(
        persist_outbound_source_in_tx(&mut transaction, &offer, None, NOW)
            .await
            .is_err()
    );
    drop(transaction);
    assert!(
        fixture
            .db
            .task_board_remote_assignment(&offer.binding.assignment_id)
            .await
            .expect("load rolled back assignment")
            .is_none()
    );
}

pub(super) async fn source_recovery_owns(db: &AsyncDaemonDb, offer: &RemoteOfferRequest) -> bool {
    db.task_board_remote_source_recovery_owns_offer(
        &offer.binding.assignment_id,
        offer.binding.fencing_epoch,
    )
    .await
    .expect("load source recovery ownership")
}

pub(super) fn snapshot_offer(template: &RemoteOfferRequest) -> (RemoteOfferRequest, Vec<u8>) {
    let content = b"portable controller repository snapshot".to_vec();
    let bundle = RemoteArtifactEntry {
        relative_path: "source/repository.bundle".into(),
        sha256: hex::encode(Sha256::digest(&content)),
        size_bytes: u64::try_from(content.len()).expect("snapshot size"),
        media_type: "application/x-git-bundle".into(),
    };
    let mut offer = template.clone();
    offer.binding.phase = TaskBoardExecutionPhase::Implementation;
    offer.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    offer.binding.action_key = "implementation:1".into();
    offer.binding.repository = REPOSITORY.into();
    offer.binding.base_revision = SOURCE_REVISION.into();
    offer.binding.expected_head_revision = None;
    offer.binding.host_instance_id = INSTANCE.into();
    if template.binding.workflow_kind != TaskBoardWorkflowKind::DefaultTask {
        offer.launch = test_codex_launch(
            TaskBoardExecutionPhase::Implementation,
            &offer.binding.execution_id,
            &offer.binding.action_key,
            "Implement the frozen task plan.",
        );
    }
    offer.source = RemoteSourceMaterial::repository_snapshot_bundle(
        REPOSITORY,
        SOURCE_REVISION,
        bundle.clone(),
    );
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![bundle],
    };
    offer.request_sha256.clear();
    (offer.seal().expect("seal outbound snapshot offer"), content)
}

pub(super) async fn enable_implementation(db: &AsyncDaemonDb) -> Result<(), CliError> {
    let mut settings = db.task_board_orchestrator_settings().await?;
    settings.local_execution_host.capabilities =
        vec![crate::task_board::TaskBoardPhaseCapabilityProfile::ImplementationWrite];
    db.replace_task_board_orchestrator_settings(&settings).await?;
    Ok(())
}
