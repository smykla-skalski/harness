use std::collections::BTreeMap;

use super::fixture::{
    AcceptanceFixture, FORK_BRANCH, FORK_REPOSITORY, HOST_ID, REPOSITORY, TlsRouterServer,
    assignment, git,
};
use super::lifecycle::{
    drive, executor_assignment, run_deep_acceptance_async, with_acceptance_environment,
};
use crate::daemon::db::TaskBoardRemoteOfferReceiptDisposition;
use crate::daemon::task_board_remote_transport::controller_authority_test_support::{
    TestTlsMaterial, test_tls_material,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferDisposition, RemoteRepositorySelector, RemoteSourceMaterial,
};
use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardAttemptState,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionOwnership, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardItem, TaskBoardPullRequestHeadIdentity,
    TaskBoardPullRequestIdentity, TaskBoardReadOnlyRunContext, TaskBoardStatus,
    TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWorkflowStatus, TaskBoardWorkflowTransitionState,
    bind_plan_approval, build_planning_result, resolve_task_board_reviewers,
};

#[derive(Clone, Copy)]
enum RepositorySource {
    Snapshot,
    Branch,
    ExactRevision,
}

struct RepositoryCase {
    name: &'static str,
    workflow: TaskBoardWorkflowKind,
    phase: TaskBoardExecutionPhase,
    source: RepositorySource,
}

const REPOSITORY_CASES: [RepositoryCase; 5] = [
    RepositoryCase {
        name: "default-task-implementation-cycle-1",
        workflow: TaskBoardWorkflowKind::DefaultTask,
        phase: TaskBoardExecutionPhase::Implementation,
        source: RepositorySource::Snapshot,
    },
    RepositoryCase {
        name: "pr-fix-implementation-cycle-1",
        workflow: TaskBoardWorkflowKind::PrFix,
        phase: TaskBoardExecutionPhase::Implementation,
        source: RepositorySource::Branch,
    },
    RepositoryCase {
        name: "pr-review-review",
        workflow: TaskBoardWorkflowKind::PrReview,
        phase: TaskBoardExecutionPhase::Review,
        source: RepositorySource::Branch,
    },
    RepositoryCase {
        name: "review-review",
        workflow: TaskBoardWorkflowKind::Review,
        phase: TaskBoardExecutionPhase::Review,
        source: RepositorySource::ExactRevision,
    },
    RepositoryCase {
        name: "review-evaluate",
        workflow: TaskBoardWorkflowKind::Review,
        phase: TaskBoardExecutionPhase::Evaluate,
        source: RepositorySource::ExactRevision,
    },
];

#[test]
fn authenticated_two_daemon_offer_acceptance_covers_repository_source_matrix() {
    run_deep_acceptance_async(|| async {
        let tls = test_tls_material();
        with_acceptance_environment(&tls, "remote-acceptance-offer-matrix", async {
            for case in REPOSITORY_CASES {
                run_repository_case(&tls, &case).await;
            }
        })
        .await;
    });
}

async fn run_repository_case(tls: &TestTlsMaterial, case: &RepositoryCase) {
    let fixture = AcceptanceFixture::new();
    let executor = fixture.executor_state("executor-offer-matrix", true).await;
    fixture.configure_matrix_executor(&executor).await;
    let server = TlsRouterServer::start(executor.clone(), tls.server_config()).await;
    let controller = fixture.controller_state("controller-offer-matrix");
    fixture
        .configure_matrix_controller(&controller, server.endpoint(), tls)
        .await;
    let controller_db = controller
        .async_db
        .get()
        .expect("matrix controller database");
    let execution_id = seed_repository_case(&fixture, controller_db, case).await;

    drive(controller_db, "seal matrix offer").await;
    let offered = assignment(controller_db, &execution_id).await;
    let offer = offered
        .require_offer()
        .expect("sealed matrix offer")
        .clone();
    assert_eq!(offered.lease_id, None);
    assert_repository_source(case, &offer.source, &offer.artifacts);

    drive(
        controller_db,
        "authenticate source and offer matrix executor",
    )
    .await;
    assert_accepted_without_claim(
        controller_db,
        executor.async_db.get().expect("executor db"),
        &offer,
    )
    .await;
    server.stop().await;
}

async fn seed_repository_case(
    fixture: &AcceptanceFixture,
    db: &crate::daemon::db::AsyncDaemonDb,
    case: &RepositoryCase,
) -> String {
    let now = crate::workspace::utc_now();
    let fork = matches!(case.source, RepositorySource::Branch);
    let (worktree, revision) = if fork {
        (
            &fixture.controller_fork_worktree,
            git(&fixture.controller_fork_worktree, &["rev-parse", "HEAD"]),
        )
    } else {
        (
            &fixture.controller_worktree,
            git(&fixture.controller_worktree, &["rev-parse", "HEAD"]),
        )
    };
    let execution_id = format!("remote-offer-{}", case.name);
    let item_id = format!("remote-offer-item-{}", case.name);
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        format!("Remote offer {}", case.name),
        "Validate the authenticated remote offer source.".into(),
        now.clone(),
    );
    configure_item(&mut item, case.workflow, &execution_id);
    let mutation = db
        .create_task_board_item(item)
        .await
        .expect("create matrix item");
    let settings = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("load matrix settings");
    let reviewers = resolve_task_board_reviewers(
        &settings.settings.reviewers,
        case.workflow,
        Some(REPOSITORY),
    )
    .expect("resolve matrix reviewers");
    let snapshot = TaskBoardWorkflowSnapshot {
        workflow_kind: case.workflow,
        execution_repository: Some(REPOSITORY.into()),
        item_revision: mutation.item_revision,
        configuration_revision: u64::try_from(settings.row_revision).expect("settings revision"),
        policy_version: settings.settings.policy_version,
        reviewer: reviewers.clone(),
        read_only_run_context: Some(TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: format!("matrix-session-{}", case.name),
            title: format!("Remote offer {}", case.name),
            body: "Validate the authenticated remote offer source.".into(),
            tags: vec!["remote-acceptance".into()],
            worktree: worktree.to_string_lossy().into_owned(),
        }),
        provider_revision: None,
    };
    let execution = execution_record(
        case,
        snapshot,
        reviewers.clone(),
        &execution_id,
        &item_id,
        &revision,
        &now,
    );
    db.create_or_load_task_board_workflow_execution(&execution)
        .await
        .expect("create matrix execution");
    db.create_task_board_execution_attempt(&attempt_for(case, &execution_id, &reviewers, &now))
        .await
        .expect("create matrix attempt");
    execution_id
}

fn configure_item(item: &mut TaskBoardItem, workflow: TaskBoardWorkflowKind, execution_id: &str) {
    item.agent_mode = if workflow.is_write() {
        AgentMode::Headless
    } else {
        AgentMode::Evaluate
    };
    item.workflow_kind = workflow;
    item.execution_repository = Some(REPOSITORY.into());
    item.session_id = Some(format!("matrix-session-{execution_id}"));
    item.work_item_id = Some(format!("matrix-task-{execution_id}"));
    item.workflow.execution_id = Some(execution_id.into());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.current_step_id = Some("remote-offer".into());
    item.status = TaskBoardStatus::InProgress;
}

fn execution_record(
    case: &RepositoryCase,
    snapshot: TaskBoardWorkflowSnapshot,
    reviewers: crate::task_board::TaskBoardResolvedReviewer,
    execution_id: &str,
    item_id: &str,
    revision: &str,
    now: &str,
) -> TaskBoardWorkflowExecutionRecord {
    let pull_request = matches!(
        case.workflow,
        TaskBoardWorkflowKind::PrFix | TaskBoardWorkflowKind::PrReview
    )
    .then(|| TaskBoardPullRequestIdentity {
        repository: REPOSITORY.into(),
        number: 41,
        head: Some(TaskBoardPullRequestHeadIdentity {
            repository: FORK_REPOSITORY.into(),
            branch: FORK_BRANCH.into(),
            revision: revision.into(),
        }),
    });
    let artifacts = if case.workflow.is_write() {
        let planning = build_planning_result(
            "# Plan\n\nValidate the remote offer.",
            ["Preserve the selected immutable source.".into()],
            &snapshot,
            execution_id,
        )
        .expect("build matrix plan");
        let approval =
            bind_plan_approval(&planning, &snapshot, execution_id, "acceptance-test", now)
                .expect("bind matrix approval");
        TaskBoardWorkflowExecutionArtifacts {
            planning_result: Some(planning),
            plan_approval: Some(approval),
            ..TaskBoardWorkflowExecutionArtifacts::default()
        }
    } else {
        TaskBoardWorkflowExecutionArtifacts::default()
    };
    TaskBoardWorkflowExecutionRecord {
        execution_id: execution_id.into(),
        item_id: item_id.into(),
        snapshot,
        resolved_reviewers: reviewers,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind: case.workflow,
            phase: Some(case.phase),
            execution_state: TaskBoardExecutionState::Preparing,
            pull_request,
            exact_head_revision: Some(revision.into()),
        },
        artifacts,
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: case
                .workflow
                .is_write()
                .then(|| {
                    BTreeMap::from([
                        (
                            "admission_owner".into(),
                            crate::daemon::db::workflow_owner(execution_id),
                        ),
                        ("task_id".into(), format!("matrix-task-{execution_id}")),
                    ])
                })
                .unwrap_or_else(|| {
                    BTreeMap::from([(
                        "admission_owner".into(),
                        crate::daemon::db::workflow_owner(execution_id),
                    )])
                }),
        },
        available_at: None,
        blocked_reason: None,
        created_at: now.into(),
        updated_at: now.into(),
        completed_at: None,
        attempts: Vec::new(),
    }
}

fn attempt_for(
    case: &RepositoryCase,
    execution_id: &str,
    reviewers: &crate::task_board::TaskBoardResolvedReviewer,
    now: &str,
) -> TaskBoardExecutionAttemptRecord {
    let action_key = match case.phase {
        TaskBoardExecutionPhase::Implementation => "implementation:1".into(),
        TaskBoardExecutionPhase::Review => format!("review:{}", reviewers.profiles[0].id),
        TaskBoardExecutionPhase::Evaluate => "evaluate".into(),
        _ => unreachable!("matrix cases contain worker phases"),
    };
    TaskBoardExecutionAttemptRecord {
        execution_id: execution_id.into(),
        action_key,
        attempt: 1,
        idempotency_key: format!("matrix-attempt-{execution_id}"),
        state: TaskBoardAttemptState::Preparing,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: now.into(),
        updated_at: now.into(),
        completed_at: None,
    }
}

fn assert_repository_source(
    case: &RepositoryCase,
    source: &RemoteSourceMaterial,
    manifest: &crate::daemon::task_board_remote_transport::wire::RemoteArtifactManifest,
) {
    match (case.source, source) {
        (
            RepositorySource::Snapshot,
            RemoteSourceMaterial::RepositorySnapshotBundle { repository, .. },
        ) => {
            assert_eq!(repository, REPOSITORY);
            assert_eq!(manifest.entries.len(), 1);
        }
        (
            RepositorySource::Branch,
            RemoteSourceMaterial::Repository {
                repository,
                selector,
                ..
            },
        ) => {
            assert_eq!(repository, FORK_REPOSITORY);
            assert_eq!(
                selector,
                &RemoteRepositorySelector::Branch {
                    branch: FORK_BRANCH.into(),
                    reference: format!("refs/heads/{FORK_BRANCH}"),
                }
            );
            assert!(manifest.entries.is_empty());
        }
        (
            RepositorySource::ExactRevision,
            RemoteSourceMaterial::Repository {
                repository,
                selector,
                ..
            },
        ) => {
            assert_eq!(repository, REPOSITORY);
            assert_eq!(selector, &RemoteRepositorySelector::ExactRevision);
            assert!(manifest.entries.is_empty());
        }
        _ => panic!(
            "matrix case '{}' selected the wrong source family: {source:?}",
            case.name
        ),
    }
}

pub(super) async fn assert_accepted_without_claim(
    controller_db: &crate::daemon::db::AsyncDaemonDb,
    executor_db: &crate::daemon::db::AsyncDaemonDb,
    offer: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
) {
    let controller = controller_db
        .task_board_remote_assignment(&offer.binding.assignment_id)
        .await
        .expect("load matrix controller assignment")
        .expect("matrix controller assignment exists");
    let executor = executor_assignment(executor_db, &offer.binding.assignment_id).await;
    assert_eq!(controller.require_offer().expect("controller offer"), offer);
    assert_eq!(executor.require_offer().expect("executor offer"), offer);
    assert_eq!(
        controller.state,
        crate::task_board::TaskBoardRemoteAssignmentState::Offered
    );
    assert_eq!(
        executor.state,
        crate::task_board::TaskBoardRemoteAssignmentState::Offered
    );
    assert!(controller.claim_receipt.is_none() && executor.claim_receipt.is_none());
    assert!(controller.start_receipt.is_none() && executor.start_receipt.is_none());
    let receipt = executor_db
        .exact_task_board_remote_offer_receipt(offer, HOST_ID)
        .await
        .expect("load executor offer receipt")
        .expect("executor offer receipt exists");
    assert_eq!(
        receipt.disposition,
        TaskBoardRemoteOfferReceiptDisposition::Accepted
    );
    assert_eq!(
        receipt.response().expect("receipt response").disposition,
        RemoteOfferDisposition::Accepted
    );
    let outbound = controller_db
        .task_board_remote_outbound_source_upload(
            &offer.binding.assignment_id,
            offer.binding.fencing_epoch,
        )
        .await
        .expect("load outbound source receipt");
    let inbound = executor_db
        .task_board_remote_source_bundle(&executor)
        .await
        .expect("load executor source receipt");
    match offer.source.requires_upload() {
        true => {
            let outbound = outbound.expect("outbound source receipt");
            assert_eq!(outbound.offer, *offer);
            let inbound = inbound.expect("executor source receipt");
            assert_eq!(inbound.offer, *offer);
            assert_eq!(
                inbound.materialized_request().expect("materialize source"),
                outbound
            );
        }
        false => {
            assert!(outbound.is_none());
            assert!(inbound.is_none());
        }
    }
}
