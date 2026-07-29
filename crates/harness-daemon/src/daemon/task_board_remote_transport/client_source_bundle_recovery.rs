use reqwest::Method;

use super::client::{RemoteExecutionHttpClient, RemoteExecutionHttpError, route_segment};
use super::routes::{
    SOURCE_BUNDLE_ABANDON_HTTP_BODY_LIMIT_BYTES, SOURCE_BUNDLE_ABANDON_PATH,
    SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES, SOURCE_BUNDLE_RECEIPT_PATH,
};
use super::wire::{
    RemoteSourceBundleAbandonRequest, RemoteSourceBundleAbandonResponse,
    RemoteSourceBundleReceiptVerificationResponse, RemoteSourceBundleUploadRequest,
};

use super::wire_limits::{
    MAX_REMOTE_RECEIPT_JSON_BYTES, MAX_REMOTE_SOURCE_RECOVERY_RESPONSE_JSON_BYTES,
};

impl RemoteExecutionHttpClient {
    pub(crate) async fn verify_source_bundle_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
    ) -> Result<RemoteSourceBundleReceiptVerificationResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteSourceBundleReceiptVerificationResponse = self
            .send_with_request_limit(
                Method::POST,
                route_segment(SOURCE_BUNDLE_RECEIPT_PATH),
                Some(request),
                SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES,
                MAX_REMOTE_SOURCE_RECOVERY_RESPONSE_JSON_BYTES,
            )
            .await?;
        response.validate(request)?;
        Ok(response)
    }

    pub(crate) async fn abandon_source_bundle(
        &self,
        request: &RemoteSourceBundleAbandonRequest,
    ) -> Result<RemoteSourceBundleAbandonResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteSourceBundleAbandonResponse = self
            .send_with_request_limit(
                Method::POST,
                route_segment(SOURCE_BUNDLE_ABANDON_PATH),
                Some(request),
                SOURCE_BUNDLE_ABANDON_HTTP_BODY_LIMIT_BYTES,
                MAX_REMOTE_RECEIPT_JSON_BYTES,
            )
            .await?;
        response.validate(request)?;
        Ok(response)
    }
}
