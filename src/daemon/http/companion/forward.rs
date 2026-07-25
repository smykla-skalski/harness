//! Mechanics of handing one request to the companion service and handing its
//! answer back.
//!
//! The daemon is the edge here: it terminated TLS on this connection itself, so
//! any `X-Forwarded-*` the caller sent is attacker-controlled and is replaced
//! rather than appended to. Hop-by-hop headers are dropped in both directions,
//! including the ones the peer named in `Connection`, so a forwarded request
//! never carries connection state that belonged to a different connection.

use std::net::SocketAddr;

use axum::Json;
use axum::body::Body;
use axum::http::header::{
    CONNECTION, HOST, PROXY_AUTHENTICATE, PROXY_AUTHORIZATION, TE, TRAILER, TRANSFER_ENCODING,
    UPGRADE,
};
use axum::http::{
    HeaderMap, HeaderName, HeaderValue, Request, Response as HttpResponse, StatusCode, Uri,
};
use axum::response::{IntoResponse, Response};
use hyper::body::Incoming;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::{Client, Error as ClientError};

use super::CompanionRouteConfig;

const COMPANION_ERROR_CODE: &str = "COMPANION_UPSTREAM";

/// Headers that describe one hop and must never be forwarded to the next one.
/// `keep-alive` has no `http` constant, so the list is spelled out.
const HOP_BY_HOP_HEADERS: &[HeaderName] = &[
    CONNECTION,
    PROXY_AUTHENTICATE,
    PROXY_AUTHORIZATION,
    TE,
    TRAILER,
    TRANSFER_ENCODING,
    UPGRADE,
];

const KEEP_ALIVE: HeaderName = HeaderName::from_static("keep-alive");
const X_FORWARDED_FOR: HeaderName = HeaderName::from_static("x-forwarded-for");
const X_FORWARDED_PROTO: HeaderName = HeaderName::from_static("x-forwarded-proto");
const X_FORWARDED_HOST: HeaderName = HeaderName::from_static("x-forwarded-host");

pub(super) async fn forward_to_companion(
    config: &CompanionRouteConfig,
    client: &Client<HttpConnector, Body>,
    peer_addr: SocketAddr,
    request: Request<Body>,
) -> Response {
    if requests_protocol_upgrade(request.headers()) {
        return upgrade_unsupported_response();
    }
    let upstream_request = match build_upstream_request(config, peer_addr, request) {
        Ok(request) => request,
        Err(response) => return response,
    };
    match client.request(upstream_request).await {
        Ok(response) => upstream_response(response),
        Err(error) => {
            log_upstream_failure(config.upstream_origin(), &error);
            upstream_unreachable_response()
        }
    }
}

fn build_upstream_request(
    config: &CompanionRouteConfig,
    peer_addr: SocketAddr,
    request: Request<Body>,
) -> Result<Request<Body>, Response> {
    let (mut parts, body) = request.into_parts();
    let forwarded_host = parts.headers.get(HOST).cloned();
    parts.uri = upstream_uri(config, &parts.uri).ok_or_else(upstream_uri_invalid_response)?;
    strip_hop_by_hop_headers(&mut parts.headers);
    // hyper derives Host from the upstream authority; leaving the public Host
    // here would make the companion answer for an origin it is not bound to.
    parts.headers.remove(HOST);
    apply_forwarded_headers(&mut parts.headers, peer_addr, forwarded_host.as_ref());
    Ok(Request::from_parts(parts, body))
}

/// Rebuild the request URI against the upstream origin, keeping the path and
/// query byte-for-byte. The prefix is deliberately not stripped.
fn upstream_uri(config: &CompanionRouteConfig, original: &Uri) -> Option<Uri> {
    let path_and_query = original
        .path_and_query()
        .map_or("/", |value| value.as_str());
    format!("{}{path_and_query}", config.upstream_origin())
        .parse::<Uri>()
        .ok()
}

fn apply_forwarded_headers(
    headers: &mut HeaderMap,
    peer_addr: SocketAddr,
    forwarded_host: Option<&HeaderValue>,
) {
    if let Ok(value) = HeaderValue::from_str(&peer_addr.ip().to_string()) {
        headers.insert(X_FORWARDED_FOR, value);
    } else {
        headers.remove(X_FORWARDED_FOR);
    }
    headers.insert(X_FORWARDED_PROTO, HeaderValue::from_static("https"));
    match forwarded_host {
        Some(host) => {
            headers.insert(X_FORWARDED_HOST, host.clone());
        }
        None => {
            headers.remove(X_FORWARDED_HOST);
        }
    }
}

fn upstream_response(response: HttpResponse<Incoming>) -> Response {
    let (mut parts, body) = response.into_parts();
    strip_hop_by_hop_headers(&mut parts.headers);
    HttpResponse::from_parts(parts, Body::new(body))
}

/// Remove every hop-by-hop header, including the ones this hop named in
/// `Connection`.
fn strip_hop_by_hop_headers(headers: &mut HeaderMap) {
    for name in connection_listed_headers(headers) {
        headers.remove(&name);
    }
    for name in HOP_BY_HOP_HEADERS {
        headers.remove(name);
    }
    headers.remove(KEEP_ALIVE);
}

fn connection_listed_headers(headers: &HeaderMap) -> Vec<HeaderName> {
    headers
        .get_all(CONNECTION)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .filter_map(|token| HeaderName::try_from(token.trim()).ok())
        .collect()
}

/// A `Connection: upgrade` request wants a protocol the daemon does not relay.
/// Answering `501` is honest; silently stripping the upgrade would leave the
/// caller waiting on a handshake that can never complete.
fn requests_protocol_upgrade(headers: &HeaderMap) -> bool {
    if headers.contains_key(UPGRADE) {
        return true;
    }
    headers
        .get_all(CONNECTION)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .any(|token| token.trim().eq_ignore_ascii_case("upgrade"))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_upstream_failure(upstream_origin: &str, error: &ClientError) {
    tracing::warn!(
        upstream = upstream_origin,
        %error,
        "companion upstream request failed"
    );
}

fn companion_error_response(status: StatusCode, message: &str) -> Response {
    (
        status,
        Json(serde_json::json!({
            "error": {
                "code": COMPANION_ERROR_CODE,
                "message": message,
            }
        })),
    )
        .into_response()
}

fn upstream_unreachable_response() -> Response {
    companion_error_response(StatusCode::BAD_GATEWAY, "companion service did not answer")
}

fn upstream_uri_invalid_response() -> Response {
    companion_error_response(
        StatusCode::BAD_GATEWAY,
        "companion request path could not be forwarded",
    )
}

fn upgrade_unsupported_response() -> Response {
    companion_error_response(
        StatusCode::NOT_IMPLEMENTED,
        "companion routing does not relay protocol upgrades",
    )
}

pub(super) fn companion_unconfigured_response() -> Response {
    companion_error_response(
        StatusCode::BAD_GATEWAY,
        "companion routing is not configured",
    )
}

#[cfg(test)]
mod tests {
    use super::{
        HeaderMap, HeaderName, HeaderValue, SocketAddr, X_FORWARDED_FOR, X_FORWARDED_HOST,
        X_FORWARDED_PROTO, apply_forwarded_headers, connection_listed_headers,
        requests_protocol_upgrade, strip_hop_by_hop_headers, upstream_uri,
    };
    use crate::daemon::http::companion::CompanionRouteConfig;

    fn config() -> CompanionRouteConfig {
        CompanionRouteConfig::new("http://127.0.0.1:8787", "/panel")
            .expect("valid companion config")
    }

    fn peer() -> SocketAddr {
        "203.0.113.7:44321".parse().expect("valid peer address")
    }

    #[test]
    fn upstream_uri_keeps_the_prefix_and_query() {
        let original = "/panel/api/me?verbose=1"
            .parse()
            .expect("valid original uri");

        let forwarded = upstream_uri(&config(), &original).expect("upstream uri");

        assert_eq!(
            forwarded.to_string(),
            "http://127.0.0.1:8787/panel/api/me?verbose=1"
        );
    }

    #[test]
    fn strip_hop_by_hop_headers_drops_connection_listed_names() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "connection",
            HeaderValue::from_static("close, x-custom-hop"),
        );
        headers.insert("x-custom-hop", HeaderValue::from_static("1"));
        headers.insert("keep-alive", HeaderValue::from_static("timeout=5"));
        headers.insert("x-kept", HeaderValue::from_static("1"));

        strip_hop_by_hop_headers(&mut headers);

        assert!(!headers.contains_key("connection"));
        assert!(!headers.contains_key("x-custom-hop"));
        assert!(!headers.contains_key("keep-alive"));
        assert!(headers.contains_key("x-kept"));
    }

    #[test]
    fn connection_listed_headers_ignores_unparseable_tokens() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "connection",
            HeaderValue::from_static("close, ,\"bad name\""),
        );

        let listed = connection_listed_headers(&headers);

        assert_eq!(listed, vec![HeaderName::from_static("close")]);
    }

    #[test]
    fn forwarded_headers_replace_caller_supplied_values() {
        let mut headers = HeaderMap::new();
        headers.insert(X_FORWARDED_FOR, HeaderValue::from_static("10.0.0.1"));
        headers.insert(X_FORWARDED_PROTO, HeaderValue::from_static("http"));
        let host = HeaderValue::from_static("daemon.example.com");

        apply_forwarded_headers(&mut headers, peer(), Some(&host));

        assert_eq!(headers[X_FORWARDED_FOR], "203.0.113.7");
        assert_eq!(headers[X_FORWARDED_PROTO], "https");
        assert_eq!(headers[X_FORWARDED_HOST], "daemon.example.com");
    }

    #[test]
    fn forwarded_host_is_removed_when_the_request_carries_no_host() {
        let mut headers = HeaderMap::new();
        headers.insert(
            X_FORWARDED_HOST,
            HeaderValue::from_static("spoofed.example"),
        );

        apply_forwarded_headers(&mut headers, peer(), None);

        assert!(!headers.contains_key(X_FORWARDED_HOST));
    }

    #[test]
    fn protocol_upgrade_is_detected_from_either_header() {
        let mut upgrade_header = HeaderMap::new();
        upgrade_header.insert("upgrade", HeaderValue::from_static("websocket"));
        let mut connection_token = HeaderMap::new();
        connection_token.insert(
            "connection",
            HeaderValue::from_static("keep-alive, Upgrade"),
        );

        assert!(requests_protocol_upgrade(&upgrade_header));
        assert!(requests_protocol_upgrade(&connection_token));
        assert!(!requests_protocol_upgrade(&HeaderMap::new()));
    }
}
