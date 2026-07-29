use std::convert::Infallible;
use std::sync::{Arc, Mutex};

use axum::body::{Body, Bytes};
use axum::extract::{Request, State};
use axum::http::{
    Method, StatusCode,
    header::{AUTHORIZATION, CONTENT_LENGTH},
};
use axum::response::Response;
use http_body_util::BodyExt as _;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio::time::{Duration, sleep};
use tokio_stream::wrappers::ReceiverStream;
use tower::ServiceExt as _;

use crate::ownership::UPLOAD_ATTACHMENT_BODY_BYTES;
use crate::{
    SybraBrowserToken, SybraGateway, SybraGatewayConfig, SybraOperation, SybraOwner,
    SybraOwnershipRegistry, SybraUpstreamToken, sybra_routes,
};

const PRIVATE_TOKEN: &str = "sybra-private-upstream-token-0123456789";
const BROWSER_TOKEN: &str = "sybra-browser-edge-token-9876543210";
type StreamSender = mpsc::Sender<Result<Bytes, Infallible>>;

#[derive(Clone, Debug)]
struct CapturedRequest {
    method: Method,
    path_and_query: String,
    authorization: Option<String>,
    body: Bytes,
}

#[derive(Clone, Default)]
struct UpstreamState {
    requests: Arc<Mutex<Vec<CapturedRequest>>>,
    held_streams: Arc<Mutex<Vec<StreamSender>>>,
}

struct TestEdge {
    router: axum::Router,
    upstream: UpstreamState,
}

impl TestEdge {
    async fn new(ownership: SybraOwnershipRegistry, ordinary: usize, streams: usize) -> Self {
        let (config, upstream) = Self::upstream().await;
        let gateway = SybraGateway::for_tests(
            config,
            ownership,
            ordinary,
            streams,
            Duration::from_millis(50),
            Duration::from_millis(100),
        );
        let router = sybra_routes(gateway, SybraBrowserToken::new(BROWSER_TOKEN.to_owned()));
        Self { router, upstream }
    }

    async fn new_default() -> Self {
        let (config, upstream) = Self::upstream().await;
        let gateway =
            SybraGateway::with_ownership(config, SybraOwnershipRegistry::default_upstream());
        let router = sybra_routes(gateway, SybraBrowserToken::new(BROWSER_TOKEN.to_owned()));
        Self { router, upstream }
    }

    async fn upstream() -> (SybraGatewayConfig, UpstreamState) {
        let upstream = UpstreamState::default();
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let address = listener.local_addr().expect("address");
        let app = axum::Router::new()
            .fallback(upstream_handler)
            .with_state(upstream.clone());
        tokio::spawn(async move {
            axum::serve(listener, app).await.expect("upstream server");
        });
        let token = SybraUpstreamToken::parse(PRIVATE_TOKEN).expect("private token");
        let config =
            SybraGatewayConfig::new(&format!("http://{address}"), token).expect("gateway config");
        (config, upstream)
    }

    fn count(&self) -> usize {
        self.upstream.requests.lock().expect("requests").len()
    }

    fn last(&self) -> CapturedRequest {
        self.upstream
            .requests
            .lock()
            .expect("requests")
            .last()
            .expect("captured request")
            .clone()
    }
}

async fn upstream_handler(State(state): State<UpstreamState>, request: Request) -> Response {
    let method = request.method().clone();
    let path_and_query = request
        .uri()
        .path_and_query()
        .expect("path and query")
        .as_str()
        .to_owned();
    let authorization = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);
    let body = request
        .into_body()
        .collect()
        .await
        .expect("request body")
        .to_bytes();
    state
        .requests
        .lock()
        .expect("requests")
        .push(CapturedRequest {
            method,
            path_and_query: path_and_query.clone(),
            authorization,
            body,
        });
    if path_and_query.starts_with("/slow-body") {
        let (sender, receiver) = mpsc::channel::<Result<Bytes, Infallible>>(1);
        tokio::spawn(async move {
            sleep(Duration::from_millis(70)).await;
            let _ = sender.send(Ok(Bytes::from_static(b"late body"))).await;
        });
        return Response::new(Body::from_stream(ReceiverStream::new(receiver)));
    }
    if path_and_query.starts_with("/slow") {
        sleep(Duration::from_millis(150)).await;
        return Response::new(Body::from("late"));
    }
    if path_and_query.contains("hold=1") {
        let (sender, receiver) = mpsc::channel::<Result<Bytes, Infallible>>(1);
        state.held_streams.lock().expect("streams").push(sender);
        return Response::new(Body::from_stream(ReceiverStream::new(receiver)));
    }
    if path_and_query.starts_with("/events") || path_and_query.starts_with("/api/events/") {
        let (sender, receiver) = mpsc::channel::<Result<Bytes, Infallible>>(1);
        tokio::spawn(async move {
            sleep(Duration::from_millis(70)).await;
            let _ = sender
                .send(Ok(Bytes::from_static(b"data: delayed\n\n")))
                .await;
        });
        return Response::new(Body::from_stream(ReceiverStream::new(receiver)));
    }
    Response::new(Body::from("upstream"))
}

fn request(method: Method, uri: &str, authenticated: bool, body: Body) -> Request {
    let mut builder = Request::builder().method(method).uri(uri);
    if authenticated {
        builder = builder.header(AUTHORIZATION, format!("Bearer {BROWSER_TOKEN}"));
    }
    builder.body(body).expect("request")
}

async fn body_text(response: Response) -> String {
    String::from_utf8(
        response
            .into_body()
            .collect()
            .await
            .expect("response body")
            .to_bytes()
            .to_vec(),
    )
    .expect("UTF-8")
}

#[tokio::test]
async fn public_routes_strip_credentials_while_rpc_uses_the_private_credential() {
    let edge = TestEdge::new(SybraOwnershipRegistry::default_upstream(), 2, 1).await;
    let health = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/health", false, Body::empty()))
        .await
        .expect("health");
    assert_eq!(health.status(), StatusCode::OK);
    assert_eq!(edge.count(), 0);
    let health_head = edge
        .router
        .clone()
        .oneshot(request(Method::HEAD, "/health", false, Body::empty()))
        .await
        .expect("health head");
    assert_eq!(health_head.status(), StatusCode::OK);
    assert!(body_text(health_head).await.is_empty());
    assert_eq!(edge.count(), 0);

    let asset = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/app.js", true, Body::empty()))
        .await
        .expect("asset");
    assert_eq!(asset.status(), StatusCode::OK);
    assert_eq!(body_text(asset).await, "upstream");
    assert_eq!(edge.last().authorization, None);
    let asset_head = edge
        .router
        .clone()
        .oneshot(request(Method::HEAD, "/app.js", false, Body::empty()))
        .await
        .expect("asset head");
    assert_eq!(asset_head.status(), StatusCode::OK);
    assert_eq!(edge.last().method, Method::HEAD);
    assert_eq!(edge.last().authorization, None);

    let rpc = edge
        .router
        .clone()
        .oneshot(request(
            Method::POST,
            &format!("/api/TaskService/Create?trace=ok&token={BROWSER_TOKEN}"),
            true,
            Body::from("payload"),
        ))
        .await
        .expect("rpc");
    assert_eq!(rpc.status(), StatusCode::OK);
    let captured = edge.last();
    assert_eq!(captured.method, Method::POST);
    assert_eq!(captured.path_and_query, "/api/TaskService/Create?trace=ok");
    assert_eq!(
        captured.authorization,
        Some(format!("Bearer {PRIVATE_TOKEN}"))
    );
    assert_eq!(captured.body, "payload");
}

#[tokio::test]
async fn private_methods_unknown_paths_and_terminal_owners_never_leak_upstream() {
    let operation = SybraOperation::Rpc {
        service: "Native".to_owned(),
        method: "Call".to_owned(),
    };
    let ownership = SybraOwnershipRegistry::default_upstream()
        .with_owner(operation, SybraOwner::Native)
        .with_owner(SybraOperation::Events, SybraOwner::Unsupported);
    let edge = TestEdge::new(ownership, 2, 1).await;
    for (method, uri, authenticated, status) in [
        (Method::POST, "/api/A/B", false, StatusCode::UNAUTHORIZED),
        (
            Method::HEAD,
            "/api/A/B",
            true,
            StatusCode::METHOD_NOT_ALLOWED,
        ),
        (
            Method::OPTIONS,
            "/api/A/B",
            true,
            StatusCode::METHOD_NOT_ALLOWED,
        ),
        (Method::GET, "/api/broken", true, StatusCode::NOT_FOUND),
        (Method::GET, "/v1/unknown", false, StatusCode::NOT_FOUND),
        (Method::GET, "/metrics", false, StatusCode::NOT_FOUND),
        (
            Method::GET,
            "/debug/pprof/profile",
            false,
            StatusCode::NOT_FOUND,
        ),
        (
            Method::POST,
            "/webhook/github",
            false,
            StatusCode::NOT_FOUND,
        ),
        (
            Method::POST,
            "/api/Native/Call",
            true,
            StatusCode::NOT_IMPLEMENTED,
        ),
        (Method::GET, "/events", true, StatusCode::NOT_IMPLEMENTED),
    ] {
        let response = edge
            .router
            .clone()
            .oneshot(request(method, uri, authenticated, Body::empty()))
            .await
            .expect("edge response");
        assert_eq!(response.status(), status, "{uri}");
    }
    assert_eq!(edge.count(), 0);
}

#[tokio::test]
async fn event_tokens_are_consumed_and_streams_have_dedicated_capacity() {
    let edge = TestEdge::new(SybraOwnershipRegistry::default_upstream(), 1, 1).await;
    let malformed = edge
        .router
        .clone()
        .oneshot(request(
            Method::GET,
            "/events?token=%zz",
            true,
            Body::empty(),
        ))
        .await
        .expect("malformed query");
    assert_eq!(malformed.status(), StatusCode::BAD_REQUEST);
    assert_eq!(edge.count(), 0);

    let malformed_rpc = edge
        .router
        .clone()
        .oneshot(request(Method::POST, "/api/A/B?trace=%zz", true, Body::empty()))
        .await
        .expect("malformed RPC query");
    assert_eq!(malformed_rpc.status(), StatusCode::BAD_REQUEST);
    assert!(body_text(malformed_rpc).await.contains("Sybra query is malformed"));
    assert_eq!(edge.count(), 0);

    for uri in ["/events", "/events?token=wrong-browser-token-000000000"] {
        let denied = edge
            .router
            .clone()
            .oneshot(request(Method::GET, uri, false, Body::empty()))
            .await
            .expect("denied event source");
        assert_eq!(denied.status(), StatusCode::UNAUTHORIZED, "{uri}");
        assert_eq!(edge.count(), 0);
    }

    let named = edge
        .router
        .clone()
        .oneshot(request(
            Method::GET,
            &format!("/api/events/task.created?token={BROWSER_TOKEN}"),
            false,
            Body::empty(),
        ))
        .await
        .expect("named event");
    assert_eq!(named.status(), StatusCode::OK);
    assert_eq!(body_text(named).await, "data: delayed\n\n");
    assert_eq!(edge.last().path_and_query, "/api/events/task.created");
    assert_eq!(
        edge.last().authorization,
        Some(format!("Bearer {PRIVATE_TOKEN}"))
    );

    let held = edge
        .router
        .clone()
        .oneshot(request(
            Method::GET,
            &format!("/events?hold=1&token={BROWSER_TOKEN}"),
            false,
            Body::empty(),
        ))
        .await
        .expect("held stream");
    assert_eq!(held.status(), StatusCode::OK);
    let captured = edge.last();
    assert_eq!(captured.path_and_query, "/events?hold=1");
    assert!(!captured.path_and_query.contains(BROWSER_TOKEN));
    assert!(!captured.path_and_query.contains(PRIVATE_TOKEN));
    assert_eq!(
        captured.authorization,
        Some(format!("Bearer {PRIVATE_TOKEN}"))
    );

    let capacity = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/events", true, Body::empty()))
        .await
        .expect("capacity");
    assert_eq!(capacity.status(), StatusCode::TOO_MANY_REQUESTS);
    let ordinary = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/asset", false, Body::empty()))
        .await
        .expect("ordinary");
    assert_eq!(ordinary.status(), StatusCode::OK);

    drop(held);
    for _ in 0..20 {
        let response = edge
            .router
            .clone()
            .oneshot(request(Method::GET, "/events", true, Body::empty()))
            .await
            .expect("released stream");
        if response.status() == StatusCode::OK {
            assert_eq!(body_text(response).await, "data: delayed\n\n");
            return;
        }
        sleep(Duration::from_millis(5)).await;
    }
    panic!("stream permit was not released");
}

#[tokio::test]
async fn default_stream_capacity_accepts_five_long_lived_tabs() {
    let edge = TestEdge::new_default().await;
    let mut streams = Vec::new();
    for index in 0..5 {
        let response = edge
            .router
            .clone()
            .oneshot(request(
                Method::GET,
                &format!("/events?hold=1&tab={index}&token={BROWSER_TOKEN}"),
                false,
                Body::empty(),
            ))
            .await
            .expect("long-lived stream");
        assert_eq!(response.status(), StatusCode::OK);
        streams.push(response);
    }
    assert_eq!(streams.len(), 5);
    assert_eq!(edge.count(), 5);
}

#[tokio::test]
async fn ordinary_deadlines_and_body_bounds_do_not_apply_to_sse_bodies() {
    let edge = TestEdge::new(SybraOwnershipRegistry::default_upstream(), 1, 1).await;
    let timed_out = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/slow", false, Body::empty()))
        .await
        .expect("timeout response");
    assert_eq!(timed_out.status(), StatusCode::GATEWAY_TIMEOUT);

    let oversized = edge
        .router
        .clone()
        .oneshot(request(
            Method::POST,
            "/api/A/B",
            true,
            Body::from(vec![b'x'; 4 * 1024 * 1024 + 1]),
        ))
        .await
        .expect("oversized response");
    assert_eq!(oversized.status(), StatusCode::PAYLOAD_TOO_LARGE);

    let large_body = vec![b'1'; 4 * 1024 * 1024 + 1];
    let upload = edge
        .router
        .clone()
        .oneshot(request(
            Method::POST,
            "/api/TaskService/UploadAttachment",
            true,
            Body::from(large_body.clone()),
        ))
        .await
        .expect("large upload");
    assert_eq!(upload.status(), StatusCode::OK);
    assert_eq!(body_text(upload).await, "upstream");
    assert_eq!(edge.last().body.len(), large_body.len());

    let mut beyond_limit = request(
        Method::POST,
        "/api/TaskService/UploadAttachment",
        true,
        Body::empty(),
    );
    beyond_limit.headers_mut().insert(
        CONTENT_LENGTH,
        (UPLOAD_ATTACHMENT_BODY_BYTES + 1)
            .to_string()
            .parse()
            .expect("content length"),
    );
    let requests_before = edge.count();
    let rejected_upload = edge
        .router
        .clone()
        .oneshot(beyond_limit)
        .await
        .expect("rejected upload");
    assert_eq!(rejected_upload.status(), StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(edge.count(), requests_before);

    let slow_body = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/slow-body", false, Body::empty()))
        .await
        .expect("slow body response");
    assert_eq!(slow_body.status(), StatusCode::OK);
    assert!(slow_body.into_body().collect().await.is_err());

    let stream = edge
        .router
        .clone()
        .oneshot(request(Method::GET, "/events", true, Body::empty()))
        .await
        .expect("stream");
    assert_eq!(stream.status(), StatusCode::OK);
    assert_eq!(body_text(stream).await, "data: delayed\n\n");
}
