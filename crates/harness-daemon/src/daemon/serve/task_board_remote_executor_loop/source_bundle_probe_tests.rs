use super::super::super::{source, source_bundle};
use super::super::git;
use super::{
    BundleSource, claim_with_start_authority, configure_executor, upload_bundle,
    workspace_owned_bundle_offer,
};
use crate::daemon::db::{remote_executor_fixture, remote_executor_identity};

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
            let error = source::validate_terminal_remote_source(&offer, &identity, &recovered)
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
