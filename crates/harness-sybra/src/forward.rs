use axum::Json;
use axum::body::Body;
use axum::http::header::{
    AUTHORIZATION, CONNECTION, HOST, PROXY_AUTHENTICATE, PROXY_AUTHORIZATION, TE, TRAILER,
    TRANSFER_ENCODING, UPGRADE,
};
use axum::http::{
    HeaderMap, HeaderName, HeaderValue, Request, Response as HttpResponse, StatusCode, Uri,
    header::CONTENT_LENGTH,
};
use axum::response::{IntoResponse, Response};
use http_body_util::{BodyExt as _, Limited};
use hyper::body::Incoming;
use tokio::sync::OwnedSemaphorePermit;
use tokio::time::{Duration, Instant, timeout_at};

use super::response_body;
use crate::SybraGatewayConfig;
use crate::client::SybraClient;

pub(super) const ORDINARY_DEADLINE: Duration = Duration::from_mins(1);
pub(super) const STREAM_HEADER_DEADLINE: Duration = Duration::from_secs(10);
const ERROR_CODE: &str = "SYBRA_UPSTREAM";
const FORWARDED: HeaderName = HeaderName::from_static("forwarded");
const X_FORWARDED_FOR: HeaderName = HeaderName::from_static("x-forwarded-for");
const X_FORWARDED_HOST: HeaderName = HeaderName::from_static("x-forwarded-host");
const X_FORWARDED_PROTO: HeaderName = HeaderName::from_static("x-forwarded-proto");

const HOP_BY_HOP_HEADERS: &[HeaderName] = &[
    CONNECTION,
    PROXY_AUTHENTICATE,
    PROXY_AUTHORIZATION,
    TE,
    TRAILER,
    TRANSFER_ENCODING,
    UPGRADE,
];

pub(super) async fn forward(
    config: &SybraGatewayConfig,
    client: &SybraClient,
    request: Request<Body>,
    permit: OwnedSemaphorePermit,
    policy: ForwardPolicy,
) -> Response {
    let deadline = Instant::now()
        + if policy.stream {
            policy.stream_header_deadline
        } else {
            policy.ordinary_deadline
        };
    let upstream_request = match build_request(config, request, policy, deadline).await {
        Ok(request) => request,
        Err(response) => return response,
    };
    match timeout_at(deadline, client.request(upstream_request)).await {
        Ok(Ok(response)) => upstream_response(response, policy.stream, deadline, permit),
        Ok(Err(_)) => {
            tracing::warn!(
                upstream = config.upstream_origin(),
                "Sybra upstream request failed"
            );
            error_response(StatusCode::BAD_GATEWAY, "Sybra upstream did not answer")
        }
        Err(_) => {
            tracing::warn!(
                upstream = config.upstream_origin(),
                "Sybra upstream response headers timed out"
            );
            error_response(
                StatusCode::GATEWAY_TIMEOUT,
                "Sybra upstream did not answer in time",
            )
        }
    }
}

#[derive(Clone, Copy)]
pub(super) struct ForwardPolicy {
    pub(super) stream: bool,
    pub(super) inject_credential: bool,
    pub(super) body_limit: usize,
    pub(super) ordinary_deadline: Duration,
    pub(super) stream_header_deadline: Duration,
}

async fn build_request(
    config: &SybraGatewayConfig,
    request: Request<Body>,
    policy: ForwardPolicy,
    deadline: Instant,
) -> Result<Request<Body>, Response> {
    let (mut parts, body) = request.into_parts();
    let original_host = original_host(&parts.headers, &parts.uri);
    parts.uri = upstream_uri(config, &parts.uri)
        .ok_or_else(|| error_response(StatusCode::BAD_GATEWAY, "Sybra path cannot be forwarded"))?;
    strip_hop_by_hop_headers(&mut parts.headers);
    parts.headers.remove(AUTHORIZATION);
    parts
        .headers
        .remove(HeaderName::from_static("x-harness-remote-client-id"));
    parts.headers.remove(FORWARDED);
    if policy.inject_credential {
        parts
            .headers
            .insert(AUTHORIZATION, config.authorization_header());
    }
    parts.headers.remove(HOST);
    apply_forwarded_headers(&mut parts.headers, original_host.as_ref());
    let body = if policy.stream {
        body
    } else {
        bounded_body(body, &parts.headers, deadline, policy.body_limit).await?
    };
    Ok(Request::from_parts(parts, body))
}

async fn bounded_body(
    body: Body,
    headers: &HeaderMap,
    deadline: Instant,
    limit: usize,
) -> Result<Body, Response> {
    if content_length_exceeds(headers, limit) {
        return Err(error_response(
            StatusCode::PAYLOAD_TOO_LARGE,
            "Sybra request body is too large",
        ));
    }
    let limited = Limited::new(body, limit);
    match timeout_at(deadline, limited.collect()).await {
        Ok(Ok(collected)) => Ok(Body::from(collected.to_bytes())),
        Ok(Err(_)) => Err(error_response(
            StatusCode::PAYLOAD_TOO_LARGE,
            "Sybra request body is too large",
        )),
        Err(_) => Err(error_response(
            StatusCode::GATEWAY_TIMEOUT,
            "Sybra request body did not arrive in time",
        )),
    }
}

fn content_length_exceeds(headers: &HeaderMap, limit: usize) -> bool {
    headers
        .get(CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .is_some_and(|length| length > limit as u64)
}

fn upstream_uri(config: &SybraGatewayConfig, original: &Uri) -> Option<Uri> {
    let path = original.path();
    let query = original.query().map(ToOwned::to_owned);
    let path_and_query = query.map_or_else(|| path.to_owned(), |query| format!("{path}?{query}"));
    format!("{}{path_and_query}", config.upstream_origin())
        .parse()
        .ok()
}

fn upstream_response(
    response: HttpResponse<Incoming>,
    stream: bool,
    deadline: Instant,
    permit: OwnedSemaphorePermit,
) -> Response {
    let (mut parts, body) = response.into_parts();
    strip_hop_by_hop_headers(&mut parts.headers);
    let body = response_body::relay(body, (!stream).then_some(deadline), permit);
    HttpResponse::from_parts(parts, body)
}

fn original_host(headers: &HeaderMap, uri: &Uri) -> Option<HeaderValue> {
    headers.get(HOST).cloned().or_else(|| {
        uri.authority()
            .and_then(|authority| HeaderValue::from_str(authority.as_str()).ok())
    })
}

fn apply_forwarded_headers(headers: &mut HeaderMap, original_host: Option<&HeaderValue>) {
    headers.remove(X_FORWARDED_FOR);
    headers.insert(X_FORWARDED_PROTO, HeaderValue::from_static("http"));
    if let Some(host) = original_host {
        headers.insert(X_FORWARDED_HOST, host.clone());
    }
}

fn strip_hop_by_hop_headers(headers: &mut HeaderMap) {
    let listed: Vec<HeaderName> = headers
        .get_all(CONNECTION)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .filter_map(|name| HeaderName::try_from(name.trim()).ok())
        .collect();
    for name in listed {
        headers.remove(name);
    }
    for name in HOP_BY_HOP_HEADERS {
        headers.remove(name);
    }
    headers.remove(HeaderName::from_static("keep-alive"));
    headers.remove(HeaderName::from_static("proxy-connection"));
}

pub(super) fn error_response(status: StatusCode, message: &str) -> Response {
    (
        status,
        Json(serde_json::json!({
            "error": {
                "code": ERROR_CODE,
                "message": message,
            }
        })),
    )
        .into_response()
}
