//! Controller HTTP call for exact executor cleanup observation.

use super::client::{RemoteExecutionHttpClient, RemoteExecutionHttpError};
use super::routes_cleanup::CLEANUP_OBSERVATION_PATH;
use super::wire_cleanup::{RemoteCleanupObservationRequest, RemoteCleanupObservationResponse};

impl RemoteExecutionHttpClient {
    pub(crate) async fn observe_cleanup(
        &self,
        request: &RemoteCleanupObservationRequest,
    ) -> Result<Option<RemoteCleanupObservationResponse>, RemoteExecutionHttpError> {
        request.validate()?;
        let path = CLEANUP_OBSERVATION_PATH
            .strip_prefix('/')
            .unwrap_or(CLEANUP_OBSERVATION_PATH);
        let response: RemoteCleanupObservationResponse = match self.post(path, request).await {
            Ok(response) => response,
            Err(RemoteExecutionHttpError::HttpStatus {
                status: 503,
                code: Some(code),
                ..
            }) if code == "REMOTE_CLEANUP_PENDING" => return Ok(None),
            Err(error) => return Err(error),
        };
        response.validate(request)?;
        Ok(Some(response))
    }
}
