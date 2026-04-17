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
use super::http::parse_error_response;
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
fn wait_for_authenticated_api_retries_until_sessions_endpoint_succeeds() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let saw_auth = Arc::new(AtomicBool::new(false));
    let session_calls = Arc::new(AtomicUsize::new(0));

    let server = {
        let saw_auth = Arc::clone(&saw_auth);
        let session_calls = Arc::clone(&session_calls);
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
                let call_index = session_calls.fetch_add(1, Ordering::SeqCst);
                if call_index == 0 {
                    write_http_response(
                        &mut stream,
                        "503 Service Unavailable",
                        "application/json",
                        "{\"error\":\"warming up\"}",
                    );
                } else {
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
    assert!(saw_auth.load(Ordering::SeqCst));
    assert_eq!(session_calls.load(Ordering::SeqCst), 2);
    server.join().expect("server");
}

#[test]
fn wait_for_authenticated_api_returns_false_when_sessions_endpoint_never_recovers() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let session_calls = Arc::new(AtomicUsize::new(0));

    let server = {
        let session_calls = Arc::clone(&session_calls);
        thread::spawn(move || {
            for _ in 0..3 {
                let (mut stream, _) = listener.accept().expect("accept");
                let _request = read_http_request(&mut stream);
                session_calls.fetch_add(1, Ordering::SeqCst);
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
    assert!(session_calls.load(Ordering::SeqCst) >= 2);
    server.join().expect("server");
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
