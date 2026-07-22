use sha2::{Digest as _, Sha256};

use super::*;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest,
};

const BUNDLE_BASE: &str = "1111111111111111111111111111111111111111";
const BUNDLE_RESULT: &str = "2222222222222222222222222222222222222222";

#[tokio::test]
async fn source_bundle_route_is_authenticated_durable_and_required_before_offer() {
    let mut state = remote_executor_state().await;
    let mut limits = state
        .remote_request_limits
        .as_ref()
        .expect("remote limits")
        .config();
    limits.max_http_body_bytes = 6 * 1024 * 1024;
    state.remote_request_limits = Some(
        crate::daemon::http::RemoteRequestLimits::new(limits)
            .expect("expanded source upload limit"),
    );
    let db = state.async_db.get().expect("async db").clone();
    let (base_url, server) = serve(state).await;
    let client = Client::new();
    let content = vec![b'b'; 3 * 1024 * 1024];
    let offer = bundle_offer(&content);
    let upload =
        RemoteSourceBundleUploadRequest::seal(offer.clone(), &content).expect("seal source upload");

    let premature = authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &offer).await;
    assert_eq!(premature.status(), StatusCode::CONFLICT);

    let denied =
        authenticated_post(&client, &base_url, SOURCE_BUNDLE_PATH, OPERATOR, &upload).await;
    assert_eq!(denied.status(), StatusCode::FORBIDDEN);

    let mut tampered = upload.clone();
    tampered.content_base64.replace_range(..1, "A");
    let rejected =
        authenticated_post(&client, &base_url, SOURCE_BUNDLE_PATH, HOST_ID, &tampered).await;
    assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);

    let first = authenticated_post(&client, &base_url, SOURCE_BUNDLE_PATH, HOST_ID, &upload).await;
    assert_eq!(first.status(), StatusCode::OK);
    let first = first
        .json::<RemoteSourceBundleUploadResponse>()
        .await
        .expect("decode source upload response");
    first.validate(&upload).expect("validate source receipt");
    let replay = authenticated_post(&client, &base_url, SOURCE_BUNDLE_PATH, HOST_ID, &upload)
        .await
        .json::<RemoteSourceBundleUploadResponse>()
        .await
        .expect("decode replayed source response");
    assert_eq!(replay, first);

    let accepted = authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &offer).await;
    assert_eq!(accepted.status(), StatusCode::OK);
    let assignment = db
        .task_board_remote_assignment(&offer.binding.assignment_id)
        .await
        .expect("load source-backed assignment")
        .expect("source-backed assignment exists");
    assert_eq!(
        db.task_board_remote_source_bundle(&assignment)
            .await
            .expect("load durable source")
            .expect("durable source exists")
            .content,
        Some(content)
    );

    server.abort();
    let _ = server.await;
}

fn bundle_offer(content: &[u8]) -> RemoteOfferRequest {
    let bundle = RemoteArtifactEntry {
        relative_path: "source/prior-phase.bundle".into(),
        sha256: hex::encode(Sha256::digest(content)),
        size_bytes: u64::try_from(content.len()).expect("bundle size"),
        media_type: "application/x-git-bundle".into(),
    };
    let mut offer = offer_request("assignment-source-route", "source-route-key");
    offer.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    // A prior-phase bundle binds the offer to the bundle's result revision.
    offer.binding.base_revision = BUNDLE_RESULT.into();
    offer.source = RemoteSourceMaterial::prior_phase_bundle(
        REPOSITORY,
        BUNDLE_BASE,
        BUNDLE_RESULT,
        bundle.clone(),
    );
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![bundle],
    };
    offer.request_sha256.clear();
    offer.seal().expect("seal bundle route offer")
}
