use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use opentelemetry::Value as OTelValue;
use opentelemetry::global;
use opentelemetry::trace::{SpanKind, TracerProvider as _};
use opentelemetry_sdk::error::OTelSdkResult;
use opentelemetry_sdk::propagation::TraceContextPropagator;
use opentelemetry_sdk::trace::{SdkTracerProvider, SpanData, SpanExporter};
use tracing_subscriber::prelude::*;

use super::DaemonClient;
use super::connection::{
    daemon_client_allowed_in_current_context, try_build_client, wait_for_authenticated_api,
};
use super::http::{mutation_timeout_for_path, parse_error_response};
use super::test_support::{read_http_request, write_http_response};

#[test]
fn try_connect_returns_none_when_no_daemon() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home).expect("create home");
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8"))),
            ("HOME", Some(home.to_str().expect("utf8 home"))),
            ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 home"))),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_DAEMON_DATA_HOME", None),
        ],
        || {
            let client = try_build_client();
            assert!(client.is_none());
        },
    );
}

#[test]
fn resolve_runtime_session_returns_resolved_match() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured_query = Arc::new(Mutex::new(String::new()));

    let server = {
        let captured_query = Arc::clone(&captured_query);
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_http_request(&mut stream);
            *captured_query.lock().expect("query capture") = request_path(&request);
            write_http_response(
                &mut stream,
                "200 OK",
                "application/json",
                "{\"resolved\":{\"orchestration_session_id\":\"sess-1\",\"agent_id\":\"codex-abc\"}}",
            );
        })
    };

    let client = DaemonClient {
        endpoint,
        token: "test-token".into(),
        http: reqwest::Client::new(),
    };
    let outcome = client
        .resolve_runtime_session("codex", "runtime-worker-42")
        .expect("resolve runtime session");

    match outcome {
        crate::daemon::client::RuntimeSessionLookup::Resolved(agent) => {
            assert_eq!(agent.orchestration_session_id, "sess-1");
            assert_eq!(agent.agent_id, "codex-abc");
        }
        other => panic!("expected Resolved, got {other:?}"),
    }
    let query = captured_query.lock().expect("query").clone();
    assert!(
        query.starts_with("/v1/runtime-sessions/resolve?"),
        "unexpected resolver query: {query}"
    );
    assert!(query.contains("runtime_name=codex"));
    assert!(query.contains("runtime_session_id=runtime-worker-42"));
    server.join().expect("server");
}

#[test]
fn resolve_runtime_session_returns_not_found_when_resolved_is_null() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let _request = read_http_request(&mut stream);
        write_http_response(
            &mut stream,
            "200 OK",
            "application/json",
            "{\"resolved\":null}",
        );
    });

    let client = DaemonClient {
        endpoint,
        token: "test-token".into(),
        http: reqwest::Client::new(),
    };
    let outcome = client
        .resolve_runtime_session("codex", "unknown")
        .expect("resolve runtime session");
    assert!(matches!(
        outcome,
        crate::daemon::client::RuntimeSessionLookup::NotFound
    ));
    server.join().expect("server");
}

#[test]
fn resolve_runtime_session_signals_endpoint_unavailable_on_404() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let _request = read_http_request(&mut stream);
        write_http_response(
            &mut stream,
            "404 Not Found",
            "application/json",
            "{\"error\":\"not found\"}",
        );
    });

    let client = DaemonClient {
        endpoint,
        token: "test-token".into(),
        http: reqwest::Client::new(),
    };
    let outcome = client
        .resolve_runtime_session("codex", "sess-worker-a")
        .expect("resolve runtime session");
    assert!(matches!(
        outcome,
        crate::daemon::client::RuntimeSessionLookup::EndpointUnavailable
    ));
    server.join().expect("server");
}

#[test]
fn parse_error_response_extracts_message() {
    let body = r#"{"error":{"code":"KSRCLI092","message":"agent conflict"}}"#;
    let error = parse_error_response(body, 400);
    assert!(error.to_string().contains("agent conflict"));
}

#[test]
fn parse_error_response_handles_plain_text() {
    let error = parse_error_response("not json", 500);
    assert!(error.to_string().contains("500"));
}

#[test]
fn wait_for_authenticated_api_retries_ready_probe_until_it_succeeds() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let saw_auth = Arc::new(AtomicBool::new(false));
    let probe_calls = Arc::new(AtomicUsize::new(0));
    let paths = Arc::new(Mutex::new(Vec::<String>::new()));

    let server = {
        let saw_auth = Arc::clone(&saw_auth);
        let probe_calls = Arc::clone(&probe_calls);
        let paths = Arc::clone(&paths);
        thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().expect("accept");
                let request = read_http_request(&mut stream);
                if request
                    .to_ascii_lowercase()
                    .contains("authorization: bearer test-token")
                {
                    saw_auth.store(true, Ordering::SeqCst);
                }
                paths
                    .lock()
                    .expect("paths lock")
                    .push(request_path(&request));
                let call_index = probe_calls.fetch_add(1, Ordering::SeqCst);
                if call_index == 0 {
                    write_http_response(
                        &mut stream,
                        "503 Service Unavailable",
                        "application/json",
                        "{\"error\":\"warming up\"}",
                    );
                } else {
                    write_http_response(
                        &mut stream,
                        "200 OK",
                        "application/json",
                        "{\"ready\":true,\"daemon_epoch\":\"test\"}",
                    );
                }
            }
        })
    };

    let client = DaemonClient {
        endpoint,
        token: "test-token".to_string(),
        http: reqwest::Client::new(),
    };
    assert!(wait_for_authenticated_api(
        &client,
        Duration::from_millis(250)
    ));
    assert!(saw_auth.load(Ordering::SeqCst));
    assert_eq!(probe_calls.load(Ordering::SeqCst), 2);
    let observed = paths.lock().expect("paths lock").clone();
    assert_eq!(observed, vec!["/v1/ready", "/v1/ready"]);
    server.join().expect("server");
}

#[test]
fn mutation_timeout_uses_longer_deadline_for_session_start() {
    assert_eq!(
        mutation_timeout_for_path("/v1/sessions"),
        Duration::from_secs(30)
    );
    assert_eq!(
        mutation_timeout_for_path("/v1/sessions/sess-123/task"),
        Duration::from_secs(5)
    );
}

#[test]
fn wait_for_authenticated_api_falls_back_to_sessions_when_ready_endpoint_is_missing() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let paths = Arc::new(Mutex::new(Vec::<String>::new()));

    let server = {
        let paths = Arc::clone(&paths);
        thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().expect("accept");
                let request = read_http_request(&mut stream);
                let path = request_path(&request);
                paths.lock().expect("paths lock").push(path.clone());
                if path == "/v1/ready" {
                    write_http_response(
                        &mut stream,
                        "404 Not Found",
                        "application/json",
                        "{\"error\":\"not found\"}",
                    );
                } else {
                    assert_eq!(path, "/v1/sessions", "unexpected fallback path: {path}");
                    write_http_response(&mut stream, "200 OK", "application/json", "[]");
                }
            }
        })
    };

    let client = DaemonClient {
        endpoint,
        token: "test-token".to_string(),
        http: reqwest::Client::new(),
    };
    assert!(wait_for_authenticated_api(
        &client,
        Duration::from_millis(250)
    ));
    let observed = paths.lock().expect("paths lock").clone();
    assert_eq!(observed, vec!["/v1/ready", "/v1/sessions"]);
    server.join().expect("server");
}

#[test]
fn wait_for_authenticated_api_returns_false_when_probe_never_recovers() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let probe_calls = Arc::new(AtomicUsize::new(0));

    let server = {
        let probe_calls = Arc::clone(&probe_calls);
        thread::spawn(move || {
            for _ in 0..3 {
                let (mut stream, _) = listener.accept().expect("accept");
                let _request = read_http_request(&mut stream);
                probe_calls.fetch_add(1, Ordering::SeqCst);
                write_http_response(
                    &mut stream,
                    "503 Service Unavailable",
                    "application/json",
                    "{\"error\":\"still warming up\"}",
                );
            }
        })
    };

    let client = DaemonClient {
        endpoint,
        token: "test-token".to_string(),
        http: reqwest::Client::new(),
    };
    assert!(!wait_for_authenticated_api(
        &client,
        Duration::from_millis(250)
    ));
    assert!(probe_calls.load(Ordering::SeqCst) >= 2);
    server.join().expect("server");
}

fn request_path(request: &str) -> String {
    let first_line = request.lines().next().unwrap_or_default();
    let mut parts = first_line.split_whitespace();
    let _method = parts.next();
    parts.next().unwrap_or_default().to_string()
}

#[test]
fn daemon_client_allowed_in_current_context_rejects_active_tokio_runtime() {
    assert!(daemon_client_allowed_in_current_context());

    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        assert!(!daemon_client_allowed_in_current_context());
    });
}

#[test]
fn daemon_client_get_injects_traceparent_and_exports_client_span() {
    let _guard = crate::telemetry::telemetry_test_guard();
    global::set_text_map_propagator(TraceContextPropagator::new());
    let exporter = TestSpanExporter::default();
    let tracer_provider = SdkTracerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    let tracer = tracer_provider.tracer("daemon-client-tests");
    let subscriber =
        tracing_subscriber::registry().with(tracing_opentelemetry::layer().with_tracer(tracer));
    let _subscriber_guard = tracing::subscriber::set_default(subscriber);

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured_request = Arc::new(Mutex::new(String::new()));
    let server = {
        let captured_request = Arc::clone(&captured_request);
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_http_request(&mut stream);
            *captured_request.lock().expect("capture request") = request;
            write_http_response(&mut stream, "200 OK", "application/json", "[]");
        })
    };

    let client = DaemonClient {
        endpoint,
        token: "test-token".to_string(),
        http: reqwest::Client::new(),
    };
    let sessions: Vec<serde_json::Value> = client.get("/v1/sessions").expect("get sessions");

    assert!(sessions.is_empty());
    server.join().expect("server");
    let _ = tracer_provider.force_flush();

    let request = captured_request
        .lock()
        .expect("captured request")
        .to_ascii_lowercase();
    assert!(request.contains("x-request-id: "));
    assert!(request.contains("traceparent: "));

    let spans = exporter.finished_spans();
    let request_span = find_exported_span(&spans, "GET /v1/sessions");

    assert_eq!(request_span.span_kind, SpanKind::Client);
    assert_eq!(
        span_string_attribute(request_span, "http.route").as_deref(),
        Some("/v1/sessions")
    );
    assert_eq!(
        span_string_attribute(request_span, "url.path").as_deref(),
        Some("/v1/sessions")
    );
}

fn find_exported_span<'a>(spans: &'a [SpanData], name: &str) -> &'a SpanData {
    spans
        .iter()
        .find(|span| span.name.as_ref() == name)
        .unwrap_or_else(|| panic!("expected span named {name}, got {spans:#?}"))
}

fn span_string_attribute(span: &SpanData, key: &str) -> Option<String> {
    span.attributes
        .iter()
        .find(|attribute| attribute.key.as_str() == key)
        .and_then(|attribute| match &attribute.value {
            OTelValue::String(value) => Some(value.as_str().to_string()),
            _ => None,
        })
}

#[derive(Clone, Debug, Default)]
struct TestSpanExporter {
    spans: Arc<Mutex<Vec<SpanData>>>,
}

impl TestSpanExporter {
    fn finished_spans(&self) -> Vec<SpanData> {
        self.spans.lock().expect("span exporter lock").clone()
    }
}

impl SpanExporter for TestSpanExporter {
    fn export(
        &self,
        batch: Vec<SpanData>,
    ) -> impl std::future::Future<Output = OTelSdkResult> + Send {
        let spans = Arc::clone(&self.spans);
        async move {
            spans.lock().expect("span exporter lock").extend(batch);
            Ok(())
        }
    }
}
