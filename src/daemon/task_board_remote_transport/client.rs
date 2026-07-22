use std::error::Error;
use std::fmt;
use std::time::Duration;

use reqwest::header::{ACCEPT, CONTENT_TYPE};
use reqwest::{Method, Url};
use rustls::ClientConfig;
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;

use super::credentials::{RemoteExecutionCredentialError, RemoteExecutionCredentialResolver};
use super::routes::{
    ADVERTISE_PATH, ARTIFACT_PATH, CANCEL_PATH, CLAIM_PATH, HEARTBEAT_PATH, LEASE_RENEW_PATH,
    OFFER_HTTP_BODY_LIMIT_BYTES, OFFER_PATH, SETTLED_PATH, SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES,
    SOURCE_BUNDLE_PATH, STATUS_PATH,
};
#[cfg(test)]
use super::tls_pin::pinned_client_config_with_roots;
use super::tls_pin::{RemoteTlsPinError, pinned_platform_client_config};
use super::wire_limits::MAX_REMOTE_LIFECYCLE_JSON_BYTES;
use super::wire::{
    RemoteArtifactFetchRequest, RemoteArtifactFetchResponse, RemoteCancelRequest,
    RemoteCancelResponse, RemoteClaimRequest, RemoteClaimResponse, RemoteHeartbeatRequest,
    RemoteHeartbeatResponse, RemoteHostAdvertisement, RemoteLeaseRenewRequest,
    RemoteLeaseRenewResponse, RemoteOfferRequest, RemoteOfferResponse, RemoteSettledRequest,
    RemoteSettledResponse, RemoteStatusRequest, RemoteStatusResponse, RemoteWireError,
    RemoteSourceBundleUploadRequest, RemoteSourceBundleUploadResponse,
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_REQUEST_BYTES: usize = MAX_REMOTE_LIFECYCLE_JSON_BYTES;
const MAX_JSON_RESPONSE_BYTES: usize = MAX_REMOTE_LIFECYCLE_JSON_BYTES;
const MAX_ARTIFACT_RESPONSE_BYTES: usize = 48 * 1024 * 1024;

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct RemoteExecutionHttpClientConfig {
    endpoint: Url,
    spki_sha256_pin: String,
    credential_reference: String,
    client_id: String,
}

impl fmt::Debug for RemoteExecutionHttpClientConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemoteExecutionHttpClientConfig")
            .field("endpoint", &self.endpoint)
            .field("spki_sha256_pin", &"<configured SPKI sha256 pin>")
            .field("credential_reference", &"<redacted reference>")
            .field("client_id", &self.client_id)
            .finish()
    }
}

impl RemoteExecutionHttpClientConfig {
    pub(crate) fn new(
        endpoint: &str,
        spki_sha256_pin: &str,
        credential_reference: &str,
        client_id: &str,
    ) -> Result<Self, RemoteExecutionHttpError> {
        let mut endpoint = Url::parse(endpoint).map_err(|_| RemoteExecutionHttpError::Config)?;
        if endpoint.scheme() != "https"
            || endpoint.host_str().is_none()
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
            || credential_reference.trim().is_empty()
            || client_id.trim().is_empty()
        {
            return Err(RemoteExecutionHttpError::Config);
        }
        let path = format!("{}/", endpoint.path().trim_end_matches('/'));
        endpoint.set_path(&path);
        Ok(Self {
            endpoint,
            spki_sha256_pin: spki_sha256_pin.to_string(),
            credential_reference: credential_reference.to_string(),
            client_id: client_id.to_string(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RemoteExecutionHttpError {
    Config,
    Tls(RemoteTlsPinError),
    Credential(RemoteExecutionCredentialError),
    RequestTooLarge,
    ResponseTooLarge,
    Transport,
    HttpStatus(u16),
    Encode,
    Decode,
    Wire(RemoteWireError),
}

impl fmt::Display for RemoteExecutionHttpError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Config => write!(formatter, "remote execution HTTP configuration is invalid"),
            Self::Tls(error) => write!(formatter, "{error}"),
            Self::Credential(error) => write!(formatter, "{error}"),
            Self::RequestTooLarge => write!(formatter, "remote execution request is too large"),
            Self::ResponseTooLarge => write!(formatter, "remote execution response is too large"),
            Self::Transport => write!(formatter, "remote execution transport failed"),
            Self::HttpStatus(status) => write!(formatter, "remote execution HTTP status {status}"),
            Self::Encode => write!(formatter, "remote execution request encoding failed"),
            Self::Decode => write!(formatter, "remote execution response decoding failed"),
            Self::Wire(error) => write!(formatter, "{error}"),
        }
    }
}

impl Error for RemoteExecutionHttpError {}

impl From<RemoteWireError> for RemoteExecutionHttpError {
    fn from(error: RemoteWireError) -> Self {
        Self::Wire(error)
    }
}

pub(crate) struct RemoteExecutionHttpClient {
    config: RemoteExecutionHttpClientConfig,
    credentials: RemoteExecutionCredentialResolver,
    client: reqwest::Client,
}

impl fmt::Debug for RemoteExecutionHttpClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemoteExecutionHttpClient")
            .field("config", &self.config)
            .finish_non_exhaustive()
    }
}

impl RemoteExecutionHttpClient {
    pub(super) fn has_config(&self, expected: &RemoteExecutionHttpClientConfig) -> bool {
        self.config == *expected
    }

    pub(crate) fn new(
        config: RemoteExecutionHttpClientConfig,
    ) -> Result<Self, RemoteExecutionHttpError> {
        let tls = pinned_platform_client_config(&config.spki_sha256_pin)
            .map_err(RemoteExecutionHttpError::Tls)?;
        Self::with_tls(config, tls)
    }

    #[cfg(test)]
    pub(super) fn new_with_roots(
        config: RemoteExecutionHttpClientConfig,
        roots: Vec<rustls::pki_types::CertificateDer<'static>>,
    ) -> Result<Self, RemoteExecutionHttpError> {
        let tls = pinned_client_config_with_roots(&config.spki_sha256_pin, roots)
            .map_err(RemoteExecutionHttpError::Tls)?;
        Self::with_tls(config, tls)
    }

    fn with_tls(
        config: RemoteExecutionHttpClientConfig,
        tls: ClientConfig,
    ) -> Result<Self, RemoteExecutionHttpError> {
        let client = reqwest::Client::builder()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .connect_timeout(CONNECT_TIMEOUT)
            .read_timeout(READ_TIMEOUT)
            .timeout(REQUEST_TIMEOUT)
            .use_preconfigured_tls(tls)
            .build()
            .map_err(|_| RemoteExecutionHttpError::Config)?;
        Ok(Self {
            config,
            credentials: RemoteExecutionCredentialResolver,
            client,
        })
    }

    pub(crate) async fn advertise(
        &self,
    ) -> Result<RemoteHostAdvertisement, RemoteExecutionHttpError> {
        let response = self
            .send::<(), RemoteHostAdvertisement>(
                Method::GET,
                route_segment(ADVERTISE_PATH),
                None,
                MAX_JSON_RESPONSE_BYTES,
            )
            .await?;
        response.validate()?;
        Ok(response)
    }

    pub(crate) async fn heartbeat(
        &self,
        request: &RemoteHeartbeatRequest,
    ) -> Result<RemoteHeartbeatResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteHeartbeatResponse =
            self.post(route_segment(HEARTBEAT_PATH), request).await?;
        response.validate(request)?;
        Ok(response)
    }

    pub(crate) async fn offer(
        &self,
        request: &RemoteOfferRequest,
    ) -> Result<RemoteOfferResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteOfferResponse = self
            .send_with_request_limit(
                Method::POST,
                route_segment(OFFER_PATH),
                Some(request),
                OFFER_HTTP_BODY_LIMIT_BYTES,
                MAX_JSON_RESPONSE_BYTES,
            )
            .await?;
        response.validate(request)?;
        Ok(response)
    }

    pub(crate) async fn upload_source_bundle(
        &self,
        request: &RemoteSourceBundleUploadRequest,
    ) -> Result<RemoteSourceBundleUploadResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteSourceBundleUploadResponse = self
            .send_with_request_limit(
                Method::POST,
                route_segment(SOURCE_BUNDLE_PATH),
                Some(request),
                SOURCE_BUNDLE_HTTP_BODY_LIMIT_BYTES,
                MAX_JSON_RESPONSE_BYTES,
            )
            .await?;
        response.validate(request)?;
        Ok(response)
    }

    pub(crate) async fn claim(
        &self,
        request: &RemoteClaimRequest,
    ) -> Result<RemoteClaimResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteClaimResponse = self.post(route_segment(CLAIM_PATH), request).await?;
        response.validate(request)?;
        Ok(response)
    }

    pub(crate) async fn renew_lease(
        &self,
        request: &RemoteLeaseRenewRequest,
    ) -> Result<RemoteLeaseRenewResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteLeaseRenewResponse =
            self.post(route_segment(LEASE_RENEW_PATH), request).await?;
        response.validate(request)?;
        Ok(response)
    }

    pub(crate) async fn status(
        &self,
        request: &RemoteStatusRequest,
    ) -> Result<RemoteStatusResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteStatusResponse = self.post(route_segment(STATUS_PATH), request).await?;
        response.validate(request)?;
        Ok(response)
    }

    pub(crate) async fn cancel(
        &self,
        request: &RemoteCancelRequest,
    ) -> Result<RemoteCancelResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteCancelResponse = self.post(route_segment(CANCEL_PATH), request).await?;
        response.validate(request)?;
        Ok(response)
    }

    pub(crate) async fn settle(
        &self,
        request: &RemoteSettledRequest,
    ) -> Result<RemoteSettledResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteSettledResponse =
            self.post(route_segment(SETTLED_PATH), request).await?;
        response.validate(request)?;
        Ok(response)
    }

    pub(crate) async fn fetch_artifact(
        &self,
        request: &RemoteArtifactFetchRequest,
    ) -> Result<RemoteArtifactFetchResponse, RemoteExecutionHttpError> {
        request.validate()?;
        let response: RemoteArtifactFetchResponse = self
            .send(
                Method::POST,
                route_segment(ARTIFACT_PATH),
                Some(request),
                MAX_ARTIFACT_RESPONSE_BYTES,
            )
            .await?;
        response.validate(request)?;
        Ok(response)
    }

    pub(super) async fn post<Request, Response>(
        &self,
        path: &str,
        request: &Request,
    ) -> Result<Response, RemoteExecutionHttpError>
    where
        Request: Serialize,
        Response: DeserializeOwned,
    {
        self.send(Method::POST, path, Some(request), MAX_JSON_RESPONSE_BYTES)
            .await
    }

    async fn send<Request, Response>(
        &self,
        method: Method,
        path: &str,
        request: Option<&Request>,
        max_response_bytes: usize,
    ) -> Result<Response, RemoteExecutionHttpError>
    where
        Request: Serialize,
        Response: DeserializeOwned,
    {
        self.send_with_request_limit(
            method,
            path,
            request,
            MAX_REQUEST_BYTES,
            max_response_bytes,
        )
        .await
    }

    pub(super) async fn send_with_request_limit<Request, Response>(
        &self,
        method: Method,
        path: &str,
        request: Option<&Request>,
        max_request_bytes: usize,
        max_response_bytes: usize,
    ) -> Result<Response, RemoteExecutionHttpError>
    where
        Request: Serialize,
        Response: DeserializeOwned,
    {
        let url = self
            .config
            .endpoint
            .join(path)
            .map_err(|_| RemoteExecutionHttpError::Config)?;
        let credential = self
            .credentials
            .resolve(&self.config.credential_reference)
            .map_err(RemoteExecutionHttpError::Credential)?;
        let mut builder = self
            .client
            .request(method, url)
            .header(ACCEPT, "application/json")
            .header(REMOTE_CLIENT_ID_HEADER, &self.config.client_id)
            .bearer_auth(credential.expose());
        if let Some(request) = request {
            let body = serde_json::to_vec(request).map_err(|_| RemoteExecutionHttpError::Encode)?;
            if body.len() > max_request_bytes {
                return Err(RemoteExecutionHttpError::RequestTooLarge);
            }
            builder = builder.header(CONTENT_TYPE, "application/json").body(body);
        }
        let response = builder
            .send()
            .await
            .map_err(|_| RemoteExecutionHttpError::Transport)?;
        if !response.status().is_success() {
            return Err(RemoteExecutionHttpError::HttpStatus(
                response.status().as_u16(),
            ));
        }
        let bytes = bounded_response(response, max_response_bytes).await?;
        serde_json::from_slice(&bytes).map_err(|_| RemoteExecutionHttpError::Decode)
    }
}

pub(super) fn route_segment(path: &'static str) -> &'static str {
    path.strip_prefix('/').unwrap_or(path)
}

async fn bounded_response(
    mut response: reqwest::Response,
    limit: usize,
) -> Result<Vec<u8>, RemoteExecutionHttpError> {
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return Err(RemoteExecutionHttpError::ResponseTooLarge);
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| RemoteExecutionHttpError::Transport)?
    {
        if bytes.len().saturating_add(chunk.len()) > limit {
            return Err(RemoteExecutionHttpError::ResponseTooLarge);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
