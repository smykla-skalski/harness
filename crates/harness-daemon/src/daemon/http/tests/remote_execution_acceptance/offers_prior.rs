use super::fixture::{HOST_ID, REPOSITORY, assignment};
use super::lifecycle::{
    drive, prepare_default_task_prior_phase_baseline, run_deep_acceptance_async,
    with_acceptance_environment,
};
use super::offers::assert_accepted_without_claim;
use crate::daemon::task_board_remote_transport::controller_authority_test_support::{
    TestTlsMaterial, test_tls_material,
};
use crate::daemon::task_board_remote_transport::wire::RemoteSourceMaterial;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardPhaseCapabilityProfile, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowKind, advance_task_board_workflow,
};

#[test]
fn authenticated_two_daemon_offer_acceptance_uses_adopted_default_task_prior_bundle_for_review() {
    run_deep_acceptance_async(|| async {
        let tls = test_tls_material();
        with_acceptance_environment(&tls, "remote-acceptance-prior-default-review", async {
            run_default_task_review_prior_bundle_case(&tls).await;
        })
        .await;
    });
}

async fn run_default_task_review_prior_bundle_case(tls: &TestTlsMaterial) {
    let baseline = prepare_default_task_prior_phase_baseline(tls).await;
    let controller_db = baseline
        .controller
        .async_db
        .get()
        .expect("prior-bundle controller database");
    advance_default_task_to_review(controller_db, &baseline.execution_id, &baseline.result_head)
        .await;

    let execution = controller_db
        .task_board_workflow_execution(&baseline.execution_id)
        .await
        .expect("load review execution")
        .expect("review execution exists");
    let prior = controller_db
        .task_board_remote_prior_phase_bundle(&execution, TaskBoardExecutionPhase::Review)
        .await
        .expect("load adopted implementation bundle")
        .expect("adopted implementation bundle exists");
    assert_eq!(prior.repository, REPOSITORY);
    assert_eq!(prior.base_revision, baseline.base_revision);
    assert_eq!(prior.result_revision, baseline.result_head);
    assert_eq!(prior.artifact.relative_path, "result/implementation.bundle");

    drive(controller_db, "seal prior-bundle review offer").await;
    let offered = assignment(controller_db, &baseline.execution_id).await;
    let offer = offered
        .require_offer()
        .expect("sealed prior-bundle review offer")
        .clone();
    assert_eq!(offered.lease_id, None);
    assert_prior_review_offer(&offer, &baseline.base_revision, &baseline.result_head);

    drive(controller_db, "authenticate prior-bundle review offer").await;
    assert_accepted_without_claim(
        controller_db,
        baseline
            .executor
            .async_db
            .get()
            .expect("prior-bundle executor database"),
        &offer,
    )
    .await;
    baseline.server.stop().await;
}

async fn advance_default_task_to_review(
    db: &crate::daemon::db::AsyncDaemonDb,
    execution_id: &str,
    result_head: &str,
) {
    let current = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load adopted implementation execution")
        .expect("adopted implementation execution exists");
    let mut review = current.clone();
    review.transition = advance_task_board_workflow(&current.transition, None, Some(result_head))
        .expect("advance adopted implementation to review");
    review.updated_at = crate::workspace::utc_now();
    db.compare_and_set_task_board_workflow_execution(
        &TaskBoardWorkflowExecutionCas::from(&current),
        &review,
    )
    .await
    .expect("persist review transition");
    let reviewer = review
        .resolved_reviewers
        .profiles
        .first()
        .expect("resolved default task reviewer");
    let now = crate::workspace::utc_now();
    db.create_task_board_execution_attempt(&TaskBoardExecutionAttemptRecord {
        execution_id: execution_id.into(),
        action_key: format!("review:{}", reviewer.id),
        attempt: 1,
        idempotency_key: format!("prior-bundle-review-{execution_id}"),
        state: TaskBoardAttemptState::Preparing,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: now.clone(),
        updated_at: now,
        completed_at: None,
    })
    .await
    .expect("create review attempt");
    let scheduled = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("reload scheduled review execution")
        .expect("scheduled review execution exists");
    let mut preparing = scheduled.clone();
    preparing.transition.execution_state = TaskBoardExecutionState::Preparing;
    preparing.updated_at = crate::workspace::utc_now();
    db.compare_and_set_task_board_workflow_execution(
        &TaskBoardWorkflowExecutionCas::from(&scheduled),
        &preparing,
    )
    .await
    .expect("promote scheduled review to preparing");
}

fn assert_prior_review_offer(
    offer: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    base_revision: &str,
    result_revision: &str,
) {
    assert_eq!(
        offer.binding.workflow_kind,
        TaskBoardWorkflowKind::DefaultTask
    );
    assert_eq!(offer.binding.phase, TaskBoardExecutionPhase::Review);
    assert!(offer.binding.action_key.starts_with("review:"));
    assert_eq!(offer.binding.repository, REPOSITORY);
    assert_eq!(offer.binding.base_revision, result_revision);
    assert_eq!(
        offer.binding.expected_head_revision.as_deref(),
        Some(result_revision)
    );
    assert_eq!(
        crate::task_board::remote_capability_for_phase(offer.binding.phase)
            .expect("review phase has a remote capability"),
        TaskBoardPhaseCapabilityProfile::ReviewReadOnly,
    );
    let RemoteSourceMaterial::PriorPhaseBundle {
        repository,
        base_revision: source_base,
        revision,
        advertised_ref,
        bundle,
        ..
    } = &offer.source
    else {
        panic!(
            "review offer did not select a prior-phase source: {:?}",
            offer.source
        );
    };
    assert_eq!(repository, REPOSITORY);
    assert_eq!(source_base, base_revision);
    assert_eq!(revision, result_revision);
    assert_eq!(
        advertised_ref,
        &format!("refs/harness/task-board/results/{result_revision}")
    );
    assert_eq!(bundle.relative_path, "result/implementation.bundle");
    assert_eq!(bundle.media_type, "application/x-git-bundle");
    assert_eq!(offer.artifacts.entries, vec![bundle.clone()]);
    assert_eq!(offer.binding.host_id, HOST_ID);
}
