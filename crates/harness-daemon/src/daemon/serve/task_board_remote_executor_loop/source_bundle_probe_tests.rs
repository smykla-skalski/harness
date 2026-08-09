use super::super::super::{disabled_tests::executor_state, source, source_bundle};
use super::super::git;
use super::{
    BundleSource, claim_with_start_authority, configure_executor, upload_bundle,
    workspace_owned_bundle_offer,
};
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::{
    REMOTE_EXECUTOR_PRINCIPAL, RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteOfferOutcome, remote_executor_claim_request, remote_executor_fixture,
    remote_executor_identity,
};
use crate::daemon::serve::test_support::{
    install_deterministic_runtime_seam, reconcile_task_board_remote_executor_tick,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict, TaskBoardRemoteAssignmentState,
    TaskBoardReviewResult, TaskBoardReviewerOutcome,
};
use chrono::{Duration, SecondsFormat, Utc};
use harness_daemon_db_queries::AsyncAgentWorkingCopyQueries;

#[tokio::test]
async fn workspace_prior_phase_probe_skips_source_audit_until_terminal_validation() {
    let data = tempfile::tempdir().expect("create isolated data root");
    let data_path = data.path().to_string_lossy().into_owned();
    Box::pin(temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(data_path.as_str())),
            ("CLAUDE_SESSION_ID", Some("remote-bundle-probe-test")),
        ],
        async {
            let source = BundleSource::new();
            let fixture = remote_executor_fixture(1).await;
            configure_executor(&fixture, source.repository.path()).await;
            let (offer, _) = workspace_owned_bundle_offer(&fixture.request, &source);
            upload_bundle(&fixture, &offer, &source.bytes).await;
            let (assignment, _authority) =
                Box::pin(claim_with_start_authority(&fixture, &offer)).await;
            let identity = remote_executor_identity(&assignment).expect("executor identity");
            let workspace =
                source::prepare_remote_workspace(&fixture.db, &assignment, &offer, &identity, true)
                    .await
                    .expect("prepare prior-phase workspace Start");
            assert_eq!(git(workspace.path(), &["rev-parse", "HEAD"]), source.result);
            let reads_after_start = source_bundle::materialized_request_read_count(&assignment);
            let applications_after_start =
                source_bundle::prior_phase_application_count(&assignment);

            let recovered = source::prepare_remote_workspace(
                &fixture.db,
                &assignment,
                &offer,
                &identity,
                false,
            )
            .await
            .expect("Probe accepts the already attached prior-phase result");

            assert_eq!(recovered.path(), workspace.path());
            assert_eq!(
                source_bundle::materialized_request_read_count(&assignment),
                reads_after_start,
                "repeat Probe must not load the retained source-bundle blob"
            );
            assert_eq!(
                source_bundle::prior_phase_application_count(&assignment),
                applications_after_start,
                "repeat Probe must not rerun the Git source audit"
            );

            git(recovered.path(), &["reset", "--hard", &source.base]);
            let error =
                source::validate_terminal_remote_source(&assignment, &offer, &identity, &recovered)
                    .await
                    .expect_err("terminal handoff rejects a cleanly drifted prior-phase source");
            assert!(
                error
                    .to_string()
                    .contains("not reached its exact attached result"),
                "unexpected terminal source fence: {error}"
            );
            assert_eq!(
                source_bundle::prior_phase_application_count(&assignment),
                applications_after_start,
                "terminal handoff must not run the mutating source recovery path"
            );
            assert_eq!(
                source_bundle::prior_phase_audit_count(&assignment),
                1,
                "terminal handoff must run one strict source audit"
            );
            assert_eq!(
                source_bundle::materialized_request_read_count(&assignment),
                reads_after_start,
                "terminal source audit must not load the retained bundle"
            );
            assert_eq!(
                git(recovered.path(), &["rev-parse", "HEAD"]),
                source.base,
                "terminal source audit must not repair the drifted checkout"
            );
        },
    ))
    .await;
}

#[tokio::test]
async fn drifted_terminal_source_settles_once_and_leaves_the_active_scan() {
    let data = tempfile::tempdir().expect("create isolated data root");
    let data_path = data.path().to_string_lossy().into_owned();
    Box::pin(temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(data_path.as_str())),
            ("CLAUDE_SESSION_ID", Some("remote-bundle-terminal-test")),
        ],
        async {
            let source = BundleSource::new();
            let fixture = remote_executor_fixture(1).await;
            configure_executor(&fixture, source.repository.path()).await;
            let mut template = fixture.request.clone();
            template.deadline_at =
                (Utc::now() + Duration::minutes(10)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
            let (offer, _) = workspace_owned_bundle_offer(&template, &source);
            upload_bundle(&fixture, &offer, &source.bytes).await;
            let assignment = Box::pin(claim_live_with_start_authority(&fixture, &offer)).await;
            let identity = remote_executor_identity(&assignment).expect("executor identity");
            let state = executor_state(&fixture.db, "instance-a");
            let seam = install_deterministic_runtime_seam().await;

            reconcile_task_board_remote_executor_tick(&state)
                .await
                .expect("start source-backed runtime");
            let running = fixture
                .db
                .task_board_remote_assignment(&assignment.assignment_id)
                .await
                .expect("load running source-backed assignment")
                .expect("running source-backed assignment");
            assert_eq!(running.state, TaskBoardRemoteAssignmentState::Running);
            let working_copy = fixture
                .db
                .load_agent_working_copy(&identity.working_copy_id)
                .await
                .expect("load running executor working copy")
                .expect("running executor working copy");
            git(
                std::path::Path::new(&working_copy.worktree_path),
                &["reset", "--hard", &source.base],
            );
            seam.arm_completed(&identity.run_id, completed_message(&running))
                .await
                .expect("arm terminal source-backed runtime");

            reconcile_task_board_remote_executor_tick(&state)
                .await
                .expect("settle invalid terminal source");
            let failed = fixture
                .db
                .task_board_remote_assignment(&assignment.assignment_id)
                .await
                .expect("load source-invalid assignment")
                .expect("source-invalid assignment");
            assert_eq!(failed.state, TaskBoardRemoteAssignmentState::Failed);
            assert_eq!(
                failed
                    .status_response
                    .as_ref()
                    .and_then(|response| response.error_code.as_deref()),
                Some("executor_source_invalid")
            );
            assert_eq!(source_bundle::prior_phase_audit_count(&assignment), 1);

            reconcile_task_board_remote_executor_tick(&state)
                .await
                .expect("settled source failure leaves active scan");
            assert_eq!(
                source_bundle::prior_phase_audit_count(&assignment),
                1,
                "settled source failure must not repeat the terminal Git audit"
            );
        },
    ))
    .await;
}

fn completed_message(record: &crate::daemon::db::TaskBoardRemoteAssignmentRecord) -> String {
    let binding = &record
        .require_offer()
        .expect("sealed executor offer")
        .binding;
    let head = binding
        .expected_head_revision
        .clone()
        .expect("exact executor head revision");
    serde_json::to_string(&TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: binding.execution_id.clone(),
        action_key: binding.action_key.clone(),
        attempt: binding.attempt,
        idempotency_key: binding.idempotency_key.clone(),
        exact_head_revision: head.clone(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: binding
                .action_key
                .strip_prefix("review:")
                .expect("review action key contains its exact profile")
                .into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: head,
                summary: "deterministic completed Probe".into(),
                findings: Vec::new(),
                structured_findings: Vec::new(),
            },
        }),
    })
    .expect("serialize canonical deterministic result")
}

async fn claim_live_with_start_authority(
    fixture: &RemoteExecutorFixture,
    offer: &crate::task_board::remote_wire::wire::RemoteOfferRequest,
) -> TaskBoardRemoteAssignmentRecord {
    let now = Utc::now();
    let offered_at = (now - Duration::seconds(2)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let claimed_at = (now - Duration::seconds(1)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let authority_at = now.to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let accepted = match fixture
        .db
        .accept_task_board_remote_assignment_offer(
            offer,
            REMOTE_EXECUTOR_PRINCIPAL,
            "instance-a",
            &offered_at,
        )
        .await
        .expect("accept live source-backed offer")
    {
        TaskBoardRemoteOfferOutcome::Created(record) => record,
        outcome => panic!("unexpected live source offer outcome: {outcome:?}"),
    };
    fixture
        .db
        .claim_task_board_remote_assignment(
            &remote_executor_claim_request(offer, &accepted),
            REMOTE_EXECUTOR_PRINCIPAL,
            &claimed_at,
        )
        .await
        .expect("claim live source-backed assignment");
    fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            "instance-a",
            &authority_at,
        )
        .await
        .expect("claim live source-backed Start authority")
        .expect("live source-backed Start authority");
    fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load live source-backed claim")
        .expect("live source-backed claim")
}
