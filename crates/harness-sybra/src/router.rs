use std::fmt;
use std::sync::Arc;

use axum::Router;
use axum::body::Body;
use axum::extract::{Extension, Path, Request};
use axum::http::{Method, StatusCode, Uri, header::AUTHORIZATION};
use axum::response::{IntoResponse, Response};
use axum::routing::any;
use tokio::sync::Semaphore;
use tokio::time::Duration;

use crate::client::SybraClients;
use crate::forward;
use crate::forward::ForwardPolicy;
use crate::ownership::DEFAULT_REQUEST_BODY_BYTES;
use crate::{
    SybraBrowserToken, SybraGatewayConfig, SybraOperation, SybraOwner, SybraOwnershipRegistry,
};

const MAX_ORDINARY_REQUESTS: usize = 8;
const MAX_STREAMS: usize = 32;

#[derive(Clone)]
pub struct SybraGateway {
    inner: Arc<SybraGatewayInner>,
}

struct SybraGatewayInner {
    config: SybraGatewayConfig,
    clients: SybraClients,
    ownership: SybraOwnershipRegistry,
    ordinary: Arc<Semaphore>,
    streams: Arc<Semaphore>,
    ordinary_deadline: Duration,
    stream_header_deadline: Duration,
}

impl fmt::Debug for SybraGateway {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SybraGateway")
            .field("config", &self.inner.config)
            .field("ownership", &self.inner.ownership)
            .finish_non_exhaustive()
    }
}

impl SybraGateway {
    #[must_use]
    pub fn new(config: SybraGatewayConfig) -> Self {
        Self::with_ownership(config, SybraOwnershipRegistry::default_upstream())
    }

    #[must_use]
    pub fn with_ownership(config: SybraGatewayConfig, ownership: SybraOwnershipRegistry) -> Self {
        Self::with_limits(
            config,
            ownership,
            MAX_ORDINARY_REQUESTS,
            MAX_STREAMS,
            forward::ORDINARY_DEADLINE,
            forward::STREAM_HEADER_DEADLINE,
        )
    }

    fn with_limits(
        config: SybraGatewayConfig,
        ownership: SybraOwnershipRegistry,
        ordinary_limit: usize,
        stream_limit: usize,
        ordinary_deadline: Duration,
        stream_header_deadline: Duration,
    ) -> Self {
        Self {
            inner: Arc::new(SybraGatewayInner {
                config,
                clients: SybraClients::new(),
                ownership,
                ordinary: Arc::new(Semaphore::new(ordinary_limit)),
                streams: Arc::new(Semaphore::new(stream_limit)),
                ordinary_deadline,
                stream_header_deadline,
            }),
        }
    }

    #[cfg(test)]
    pub(crate) fn for_tests(
        config: SybraGatewayConfig,
        ownership: SybraOwnershipRegistry,
        ordinary_limit: usize,
        stream_limit: usize,
        ordinary_deadline: Duration,
        stream_header_deadline: Duration,
    ) -> Self {
        Self::with_limits(
            config,
            ownership,
            ordinary_limit,
            stream_limit,
            ordinary_deadline,
            stream_header_deadline,
        )
    }
}

pub fn sybra_routes<S>(gateway: SybraGateway, browser_token: SybraBrowserToken) -> Router<S>
where
    S: Clone + Send + Sync + 'static,
{
    Router::new()
        .route("/health", any(health))
        .route("/api/{service}/{method}", any(api_operation))
        .route("/events", any(events))
        .route("/api", any(private_not_found))
        .route("/api/", any(private_not_found))
        .route("/v1", any(not_found))
        .route("/v1/{*unknown}", any(not_found))
        .route("/metrics", any(not_found))
        .route("/debug/pprof", any(not_found))
        .route("/debug/pprof/{*unknown}", any(not_found))
        .route("/webhook", any(not_found))
        .route("/webhook/{*unknown}", any(not_found))
        .fallback(any(fallback))
        .layer(Extension(browser_token))
        .layer(Extension(gateway))
}

async fn health(request: Request) -> Response {
    if !matches!(request.method(), &Method::GET | &Method::HEAD) {
        return StatusCode::METHOD_NOT_ALLOWED.into_response();
    }
    if request.method() == Method::HEAD {
        return StatusCode::OK.into_response();
    }
    (
        StatusCode::OK,
        axum::Json(serde_json::json!({"status": "ok", "service": "sybra-gateway"})),
    )
        .into_response()
}

async fn api_operation(
    Extension(gateway): Extension<SybraGateway>,
    Extension(browser_token): Extension<SybraBrowserToken>,
    Path((service, method)): Path<(String, String)>,
    mut request: Request,
) -> Response {
    let query_tokens = match sanitize_token_query(&mut request) {
        Ok(tokens) => tokens,
        Err(MalformedQuery) => return malformed_query_response(),
    };
    let query_auth_allowed = service == "events";
    if !browser_authorized(
        &request,
        &browser_token,
        query_auth_allowed.then_some(query_tokens.as_slice()),
    ) {
        return unauthorized_response();
    }
    if service == "events" {
        if request.method() != Method::GET {
            return StatusCode::METHOD_NOT_ALLOWED.into_response();
        }
        return execute(gateway, request, SybraOperation::NamedEvent(method), true).await;
    }
    if request.method() != Method::POST {
        return StatusCode::METHOD_NOT_ALLOWED.into_response();
    }
    execute(
        gateway,
        request,
        SybraOperation::Rpc { service, method },
        false,
    )
    .await
}

async fn events(
    Extension(gateway): Extension<SybraGateway>,
    Extension(browser_token): Extension<SybraBrowserToken>,
    request: Request,
) -> Response {
    private_stream(gateway, browser_token, request, SybraOperation::Events).await
}

async fn private_stream(
    gateway: SybraGateway,
    browser_token: SybraBrowserToken,
    mut request: Request,
    operation: SybraOperation,
) -> Response {
    let query_tokens = match sanitize_token_query(&mut request) {
        Ok(tokens) => tokens,
        Err(MalformedQuery) => return malformed_query_response(),
    };
    if !browser_authorized(&request, &browser_token, Some(&query_tokens)) {
        return unauthorized_response();
    }
    if request.method() != Method::GET {
        return StatusCode::METHOD_NOT_ALLOWED.into_response();
    }
    execute(gateway, request, operation, true).await
}

async fn execute(
    gateway: SybraGateway,
    request: Request,
    operation: SybraOperation,
    stream: bool,
) -> Response {
    let body_limit = operation.request_body_limit();
    match gateway.inner.ownership.owner(&operation) {
        SybraOwner::Upstream => forward_upstream(&gateway, request, stream, true, body_limit).await,
        SybraOwner::Native => terminal_owner_response("SYBRA_NATIVE_UNAVAILABLE"),
        SybraOwner::Unsupported => terminal_owner_response("SYBRA_UNSUPPORTED"),
    }
}

async fn forward_upstream(
    gateway: &SybraGateway,
    request: Request,
    stream: bool,
    inject_credential: bool,
    body_limit: usize,
) -> Response {
    let permits = if stream {
        &gateway.inner.streams
    } else {
        &gateway.inner.ordinary
    };
    let Ok(permit) = Arc::clone(permits).try_acquire_owned() else {
        return capacity_response();
    };
    let client = gateway.inner.clients.for_version(request.version());
    forward::forward(
        &gateway.inner.config,
        client,
        request,
        permit,
        ForwardPolicy {
            stream,
            inject_credential,
            body_limit,
            ordinary_deadline: gateway.inner.ordinary_deadline,
            stream_header_deadline: gateway.inner.stream_header_deadline,
        },
    )
    .await
}

fn browser_authorized(
    request: &Request,
    browser_token: &SybraBrowserToken,
    query_tokens: Option<&[String]>,
) -> bool {
    let header = browser_token.accepts_header(request.headers().get(AUTHORIZATION));
    let query = query_tokens.is_some_and(|tokens| {
        tokens.iter().fold(false, |accepted, candidate| {
            accepted | browser_token.accepts_secret(candidate)
        })
    });
    header | query
}

struct MalformedQuery;

fn sanitize_token_query(request: &mut Request) -> Result<Vec<String>, MalformedQuery> {
    let Some(query) = request.uri().query() else {
        return Ok(Vec::new());
    };
    if !is_well_formed_percent_encoding(query) {
        return Err(MalformedQuery);
    }
    let pairs =
        serde_urlencoded::from_str::<Vec<(String, String)>>(query).map_err(|_| MalformedQuery)?;
    let (tokens, kept): (Vec<_>, Vec<_>) = pairs.into_iter().partition(|(name, _)| name == "token");
    let tokens = tokens.into_iter().map(|(_, value)| value).collect();
    let query = serde_urlencoded::to_string(kept).map_err(|_| MalformedQuery)?;
    let path_and_query = if query.is_empty() {
        request.uri().path().to_owned()
    } else {
        format!("{}?{query}", request.uri().path())
    };
    *request.uri_mut() = path_and_query.parse::<Uri>().map_err(|_| MalformedQuery)?;
    Ok(tokens)
}

fn is_well_formed_percent_encoding(query: &str) -> bool {
    let bytes = query.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len()
                || !bytes[index + 1].is_ascii_hexdigit()
                || !bytes[index + 2].is_ascii_hexdigit()
            {
                return false;
            }
            index += 3;
        } else {
            index += 1;
        }
    }
    true
}

fn malformed_query_response() -> Response {
    (
        StatusCode::BAD_REQUEST,
        axum::Json(serde_json::json!({
            "error": {
                "code": "SYBRA_BAD_QUERY",
                "message": "Sybra query is malformed",
            }
        })),
    )
        .into_response()
}

fn unauthorized_response() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        axum::Json(serde_json::json!({
            "error": {
                "code": "SYBRA_UNAUTHORIZED",
                "message": "Sybra browser token is required",
            }
        })),
    )
        .into_response()
}

fn capacity_response() -> Response {
    (
        StatusCode::TOO_MANY_REQUESTS,
        axum::Json(serde_json::json!({
            "error": {
                "code": "SYBRA_CAPACITY",
                "message": "Sybra gateway capacity is exhausted",
            }
        })),
    )
        .into_response()
}

fn terminal_owner_response(code: &'static str) -> Response {
    (
        StatusCode::NOT_IMPLEMENTED,
        axum::Json(serde_json::json!({
            "error": {
                "code": code,
                "message": "Sybra operation has no executable handler",
            }
        })),
    )
        .into_response()
}

async fn private_not_found(
    Extension(browser_token): Extension<SybraBrowserToken>,
    request: Request,
) -> Response {
    if browser_authorized(&request, &browser_token, None) {
        StatusCode::NOT_FOUND.into_response()
    } else {
        unauthorized_response()
    }
}

async fn not_found() -> Response {
    StatusCode::NOT_FOUND.into_response()
}

async fn asset(Extension(gateway): Extension<SybraGateway>, request: Request<Body>) -> Response {
    if !matches!(request.method(), &Method::GET | &Method::HEAD) {
        return StatusCode::METHOD_NOT_ALLOWED.into_response();
    }
    forward_upstream(&gateway, request, false, false, DEFAULT_REQUEST_BODY_BYTES).await
}

async fn fallback(
    Extension(gateway): Extension<SybraGateway>,
    Extension(browser_token): Extension<SybraBrowserToken>,
    request: Request<Body>,
) -> Response {
    if request.uri().path().starts_with("/api/") {
        return private_not_found(Extension(browser_token), request).await;
    }
    asset(Extension(gateway), request).await
}
