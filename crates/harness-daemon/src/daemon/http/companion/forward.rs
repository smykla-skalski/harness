//! Mechanics of handing one request to the companion service and handing its
//! answer back.
//!
//! The daemon is the edge here: it terminated TLS on this connection itself, so
//! any `X-Forwarded-*` the caller sent is attacker-controlled and is replaced
//! rather than appended to. Hop-by-hop headers are dropped in both directions,
//! including the ones the peer named in `Connection`, so a forwarded request
//! never carries connection state that belonged to a different connection.

use std::net::SocketAddr;
use std::time::Duration;

use axum::Json;
use axum::body::Body;
use axum::http::header::{
    AUTHORIZATION, CONNECTION, HOST, PROXY_AUTHENTICATE, PROXY_AUTHORIZATION, TE, TRAILER,
    TRANSFER_ENCODING, UPGRADE,
};
use axum::http::{
    HeaderMap, HeaderName, HeaderValue, Method, Request, Response as HttpResponse, StatusCode, Uri,
};
use axum::response::{IntoResponse, Response};
use hyper::body::Incoming;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::{Client, Error as ClientError};
use tokio::sync::OwnedSemaphorePermit;
use tokio::time::{Instant, timeout_at};

use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;

use super::CompanionRouteConfig;
use super::response_body::stream_upstream_body;
use super::upgrade;

const COMPANION_ERROR_CODE: &str = "COMPANION_UPSTREAM";
pub(super) const COMPANION_UPSTREAM_TIMEOUT: Duration = Duration::from_mins(1);

/// Headers that describe one hop and must never be forwarded to the next one.
const HOP_BY_HOP_HEADERS: &[HeaderName] = &[
    CONNECTION,
    PROXY_AUTHENTICATE,
    PROXY_AUTHORIZATION,
    TE,
    TRAILER,
    TRANSFER_ENCODING,
    UPGRADE,
];

/// The same, for names `http` has no constant for. They cannot join
/// `HOP_BY_HOP_HEADERS`: a custom `HeaderName` is interior-mutable, and a
/// `const` slice of them is a borrow of a temporary the compiler refuses.
///
/// `Proxy-Connection` is in no RFC, but browsers and intermediaries still send
/// it and it means what `Connection` means, so forwarding it hands the
/// companion a directive about a connection it is not on.
fn unnamed_hop_by_hop_headers() -> [HeaderName; 2] {
    [
        HeaderName::from_static("keep-alive"),
        HeaderName::from_static("proxy-connection"),
    ]
}
/// RFC 7239's header. The daemon states the hop in `X-Forwarded-*` instead, so
/// a caller-supplied `Forwarded` would be an unverified claim the companion
/// might believe.
const FORWARDED: HeaderName = HeaderName::from_static("forwarded");
const X_FORWARDED_FOR: HeaderName = HeaderName::from_static("x-forwarded-for");
const X_FORWARDED_PROTO: HeaderName = HeaderName::from_static("x-forwarded-proto");
const X_FORWARDED_HOST: HeaderName = HeaderName::from_static("x-forwarded-host");

#[expect(
    clippy::cognitive_complexity,
    reason = "forwards a companion request upstream and maps its upgrade, build, unreachable, and timeout outcomes; the one inline tracing::warn! for a timed-out request costs 7 of its 11 points, leaving structural 4"
)]
pub(super) async fn forward_to_companion(
    config: &CompanionRouteConfig,
    client: &Client<HttpConnector, Body>,
    peer_addr: SocketAddr,
    request: Request<Body>,
    websocket_permit: Option<OwnedSemaphorePermit>,
) -> Response {
    if requests_protocol_upgrade(request.method(), request.headers()) {
        if !upgrade::requests_websocket_upgrade(request.method(), request.headers()) {
            return upgrade_unsupported_response();
        }
        return upgrade::relay_websocket(config, client, peer_addr, request, websocket_permit)
            .await;
    }
    let upstream_request = match build_upstream_request(config, peer_addr, request) {
        Ok(request) => request,
        Err(response) => return *response,
    };
    let deadline = Instant::now() + COMPANION_UPSTREAM_TIMEOUT;
    match timeout_at(deadline, client.request(upstream_request)).await {
        Ok(Ok(response)) => upstream_response(response, deadline, config.upstream_origin()),
        Ok(Err(error)) => {
            log_upstream_failure(config.upstream_origin(), &error);
            upstream_unreachable_response()
        }
        Err(_) => {
            tracing::warn!(
                upstream = config.upstream_origin(),
                "companion upstream request timed out"
            );
            upstream_timeout_response()
        }
    }
}

pub(super) fn build_upstream_request(
    config: &CompanionRouteConfig,
    peer_addr: SocketAddr,
    request: Request<Body>,
) -> Result<Request<Body>, Box<Response>> {
    let (mut parts, body) = request.into_parts();
    let forwarded_host = original_host(&parts.headers, &parts.uri);
    parts.uri = upstream_uri(config, &parts.uri)
        .ok_or_else(|| Box::new(upstream_uri_invalid_response()))?;
    strip_hop_by_hop_headers(&mut parts.headers);
    strip_daemon_credentials(&mut parts.headers);
    apply_companion_authorization(&mut parts.headers, config);
    // hyper derives Host from the upstream authority; leaving the public Host
    // here would make the companion answer for an origin it is not bound to.
    parts.headers.remove(HOST);
    apply_forwarded_headers(&mut parts.headers, peer_addr, forwarded_host.as_ref());
    Ok(Request::from_parts(parts, body))
}

/// A caller credential that happens to ride a request under the prefix - a
/// reused token, a cached browser header - must stop here rather than override
/// the daemon's own loopback credential.
fn strip_daemon_credentials(headers: &mut HeaderMap) {
    headers.remove(AUTHORIZATION);
    headers.remove(REMOTE_CLIENT_ID_HEADER);
    headers.remove(FORWARDED);
}

fn apply_companion_authorization(headers: &mut HeaderMap, config: &CompanionRouteConfig) {
    headers.insert(AUTHORIZATION, config.authorization_header());
}

/// The public host the caller actually addressed.
///
/// The remote listener advertises `h2` ahead of `http/1.1`, so a browser
/// normally negotiates HTTP/2, where there is no `Host` header at all - the
/// authority arrives as `:authority` and hyper records it on the URI. Reading
/// only the header would drop `X-Forwarded-Host` for exactly the callers the
/// companion is built for.
fn original_host(headers: &HeaderMap, uri: &Uri) -> Option<HeaderValue> {
    headers.get(HOST).cloned().or_else(|| {
        uri.authority()
            .and_then(|authority| HeaderValue::from_str(authority.as_str()).ok())
    })
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

pub(super) fn upstream_response(
    response: HttpResponse<Incoming>,
    deadline: Instant,
    upstream: &str,
) -> Response {
    let (mut parts, body) = response.into_parts();
    strip_hop_by_hop_headers(&mut parts.headers);
    let (body, lease) = stream_upstream_body(body, deadline, upstream);
    let mut response = HttpResponse::from_parts(parts, body);
    response.extensions_mut().insert(lease);
    response
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
    for name in unnamed_hop_by_hop_headers() {
        headers.remove(name);
    }
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

/// An upgrade request wants a protocol the daemon does not relay.
/// Answering `501` is honest; silently stripping the upgrade would leave the
/// caller waiting on a handshake that can never complete.
fn requests_protocol_upgrade(method: &Method, headers: &HeaderMap) -> bool {
    method == Method::CONNECT || headers.contains_key(UPGRADE) || connection_names_upgrade(headers)
}

pub(super) fn connection_names_upgrade(headers: &HeaderMap) -> bool {
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

pub(super) fn upstream_unreachable_response() -> Response {
    companion_error_response(StatusCode::BAD_GATEWAY, "companion service did not answer")
}

pub(super) fn upstream_timeout_response() -> Response {
    companion_error_response(
        StatusCode::GATEWAY_TIMEOUT,
        "companion service did not answer in time",
    )
}

fn upstream_uri_invalid_response() -> Response {
    companion_error_response(
        StatusCode::BAD_GATEWAY,
        "companion request path could not be forwarded",
    )
}

pub(super) fn upgrade_unsupported_response() -> Response {
    companion_error_response(
        StatusCode::NOT_IMPLEMENTED,
        "companion routing relays only websocket upgrades",
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
        AUTHORIZATION, HOST, HeaderMap, HeaderName, HeaderValue, Method, SocketAddr,
        X_FORWARDED_FOR, X_FORWARDED_HOST, X_FORWARDED_PROTO, apply_companion_authorization,
        apply_forwarded_headers, connection_listed_headers, original_host,
        requests_protocol_upgrade, strip_daemon_credentials, strip_hop_by_hop_headers,
        upstream_uri,
    };
    use crate::daemon::http::companion::{CompanionAuthToken, CompanionRouteConfig};

    const TEST_TOKEN: &str = "daemon-panel-test-token-0123456789";

    fn config() -> CompanionRouteConfig {
        let token = CompanionAuthToken::parse(TEST_TOKEN).expect("valid companion auth token");
        CompanionRouteConfig::new("http://127.0.0.1:8787", "/panel", token)
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
        headers.insert("proxy-connection", HeaderValue::from_static("keep-alive"));
        headers.insert("x-kept", HeaderValue::from_static("1"));

        strip_hop_by_hop_headers(&mut headers);

        assert!(!headers.contains_key("connection"));
        assert!(!headers.contains_key("x-custom-hop"));
        assert!(!headers.contains_key("keep-alive"));
        assert!(!headers.contains_key("proxy-connection"));
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
    fn public_host_survives_an_http2_request_that_carries_no_host_header() {
        let uri = "https://daemon.example.com/panel/"
            .parse()
            .expect("valid h2 request uri");

        let host = original_host(&HeaderMap::new(), &uri).expect("authority stands in for Host");

        assert_eq!(host, "daemon.example.com");
    }

    #[test]
    fn an_explicit_host_header_wins_over_the_uri_authority() {
        let mut headers = HeaderMap::new();
        headers.insert(HOST, HeaderValue::from_static("daemon.example.com"));
        let uri = "http://127.0.0.1:8787/panel/"
            .parse()
            .expect("valid origin-form uri");

        let host = original_host(&headers, &uri).expect("header host");

        assert_eq!(host, "daemon.example.com");
    }

    #[test]
    fn daemon_credentials_never_reach_the_companion() {
        let mut headers = HeaderMap::new();
        headers.insert("authorization", HeaderValue::from_static("Bearer secret"));
        headers.insert(
            "x-harness-remote-client-id",
            HeaderValue::from_static("viewer"),
        );
        headers.insert("forwarded", HeaderValue::from_static("for=10.0.0.1"));
        headers.insert("cookie", HeaderValue::from_static("panel_session=abc"));

        strip_daemon_credentials(&mut headers);

        assert!(!headers.contains_key("authorization"));
        assert!(!headers.contains_key("x-harness-remote-client-id"));
        assert!(!headers.contains_key("forwarded"));
        assert!(
            headers.contains_key("cookie"),
            "the companion's own session cookie must survive"
        );
    }

    #[test]
    fn companion_authorization_replaces_every_caller_value() {
        let mut headers = HeaderMap::new();
        headers.append(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer attacker-one"),
        );
        headers.append(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer attacker-two"),
        );

        strip_daemon_credentials(&mut headers);
        apply_companion_authorization(&mut headers, &config());

        let values = headers
            .get_all(AUTHORIZATION)
            .iter()
            .map(|value| value.to_str().expect("ASCII authorization"))
            .collect::<Vec<_>>();
        assert_eq!(values, vec![format!("Bearer {TEST_TOKEN}")]);
    }

    #[test]
    fn protocol_upgrade_is_detected_from_method_or_either_header() {
        let mut upgrade_header = HeaderMap::new();
        upgrade_header.insert("upgrade", HeaderValue::from_static("websocket"));
        let mut connection_token = HeaderMap::new();
        connection_token.insert(
            "connection",
            HeaderValue::from_static("keep-alive, Upgrade"),
        );

        assert!(requests_protocol_upgrade(&Method::GET, &upgrade_header));
        assert!(requests_protocol_upgrade(&Method::GET, &connection_token));
        assert!(requests_protocol_upgrade(
            &Method::CONNECT,
            &HeaderMap::new()
        ));
        assert!(!requests_protocol_upgrade(&Method::GET, &HeaderMap::new()));
    }
}
