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

    let asset_uri = format!("/app.js?cache=1&token={BROWSER_TOKEN}");
    let asset = edge
        .router
        .clone()
        .oneshot(request(Method::GET, &asset_uri, true, Body::empty()))
        .await
        .expect("asset");
    assert_eq!(asset.status(), StatusCode::OK);
    assert_eq!(body_text(asset).await, "upstream");
    assert_eq!(edge.last().authorization, None);
    assert_eq!(edge.last().path_and_query, "/app.js?cache=1");
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

#[path = "gateway_tests_streaming.rs"]
mod streaming;
