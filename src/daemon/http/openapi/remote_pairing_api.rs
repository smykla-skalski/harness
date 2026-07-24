//! Remote client pairing [`utoipa::OpenApi`] aggregator. Kept in its own module
//! so the path list does not push `openapi/mod.rs` past the file-length cap.

#[derive(utoipa::OpenApi)]
#[openapi(paths(
    super::super::remote_pairing::post_remote_pair_claim,
    super::super::remote_pairing::status::post_remote_pair_status,
    super::super::remote_clients::post_remote_client_self_revoke,
))]
pub(super) struct RemotePairingApi;
