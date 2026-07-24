//! Remote-execution transport [`utoipa::OpenApi`] aggregator. Kept in its own
//! module so the path list does not push `openapi/mod.rs` past the file-length
//! cap.
//!
//! The transport carries controller-to-executor task dispatch over HTTP with no
//! WebSocket mirror. Its routes are documented here but sit outside
//! `HTTP_API_CONTRACT` by design, so the contract test recognises them through
//! `task_board_remote_transport::execution_operation` rather than the contract.

#[derive(utoipa::OpenApi)]
#[openapi(paths(
    crate::daemon::task_board_remote_transport::routes::advertise,
    crate::daemon::task_board_remote_transport::routes::offer,
    crate::daemon::task_board_remote_transport::routes::upload_source_bundle,
    crate::daemon::task_board_remote_transport::routes_source_bundle::verify_source_bundle_receipt,
    crate::daemon::task_board_remote_transport::routes_source_bundle::abandon_source_bundle,
    crate::daemon::task_board_remote_transport::routes::claim,
    crate::daemon::task_board_remote_transport::routes::renew_lease,
    crate::daemon::task_board_remote_transport::routes::status,
    crate::daemon::task_board_remote_transport::routes::cancel,
    crate::daemon::task_board_remote_transport::routes::settled,
    crate::daemon::task_board_remote_transport::routes::fetch_artifact,
    crate::daemon::task_board_remote_transport::routes_cleanup::observe_cleanup,
))]
pub(super) struct TaskBoardExecutionApi;
