use std::sync::{Arc, Mutex};

use axum::Router;
use axum::middleware;
use axum::routing::get;
use opentelemetry::Value as OTelValue;
use opentelemetry::global;
use opentelemetry::trace::{SpanKind, TracerProvider as _};
use opentelemetry_sdk::error::OTelSdkResult;
use opentelemetry_sdk::propagation::TraceContextPropagator;
use opentelemetry_sdk::trace::{SdkTracerProvider, SpanData, SpanExporter};
use tokio::sync::Notify;
use tokio::net::TcpListener;
use tracing_subscriber::prelude::*;

#[tokio::test(flavor = "current_thread")]
async fn trace_http_request_uses_route_name_and_parent_trace_context() {
    global::set_text_map_propagator(TraceContextPropagator::new());
    let exporter = TestSpanExporter::default();
    let tracer_provider = SdkTracerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    let tracer = tracer_provider.tracer("daemon-http-tests");
    let subscriber =
        tracing_subscriber::registry().with(tracing_opentelemetry::layer().with_tracer(tracer));
    let _subscriber_guard = tracing::subscriber::set_default(subscriber);

    let app = Router::new()
        .route(
            "/v1/projects/{project_id}",
            get(|| async { axum::Json(serde_json::json!({ "ok": true })) }),
        )
        .layer(middleware::from_fn(crate::daemon::http::trace_http_request));
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });

    {
        let parent_span = tracing::info_span!("monitor.http.client", otel.kind = "client");
        let _parent_guard = parent_span.enter();
        let headers = crate::telemetry::current_trace_headers();
        let client = reqwest::Client::new();
        let mut request = client.get(format!("http://{addr}/v1/projects/demo"));
        for (header, value) in &headers {
            request = request.header(header, value);
        }
        let response = request.send().await.expect("send request");
        assert_eq!(response.status(), reqwest::StatusCode::OK);
    }

    server.abort();
    let _ = server.await;
    let _ = tracer_provider.force_flush();

    let spans = exporter.finished_spans();
    let parent_span = find_exported_span(&spans, "monitor.http.client");
    let request_span = find_exported_span(&spans, "GET /v1/projects/{project_id}");

    assert_eq!(request_span.span_kind, SpanKind::Server);
    assert_eq!(
        request_span.parent_span_id,
        parent_span.span_context.span_id()
    );
    assert_eq!(
        request_span.span_context.trace_id(),
        parent_span.span_context.trace_id()
    );
    assert_eq!(
        span_string_attribute(request_span, "http.route").as_deref(),
        Some("/v1/projects/{project_id}")
    );
    assert_eq!(
        span_string_attribute(request_span, "url.path").as_deref(),
        Some("/v1/projects/{project_id}")
    );
}

#[tokio::test(flavor = "current_thread")]
async fn trace_http_request_does_not_inherit_concurrent_request_trace_context() {
    global::set_text_map_propagator(TraceContextPropagator::new());
    let exporter = TestSpanExporter::default();
    let tracer_provider = SdkTracerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    let tracer = tracer_provider.tracer("daemon-http-tests");
    let subscriber =
        tracing_subscriber::registry().with(tracing_opentelemetry::layer().with_tracer(tracer));
    let _subscriber_guard = tracing::subscriber::set_default(subscriber);

    let slow_started = Arc::new(Notify::new());
    let release_slow = Arc::new(Notify::new());
    let app = Router::new()
        .route(
            "/slow",
            get({
                let slow_started = Arc::clone(&slow_started);
                let release_slow = Arc::clone(&release_slow);
                move || {
                    let slow_started = Arc::clone(&slow_started);
                    let release_slow = Arc::clone(&release_slow);
                    async move {
                        slow_started.notify_one();
                        release_slow.notified().await;
                        axum::Json(serde_json::json!({ "ok": true }))
                    }
                }
            }),
        )
        .route(
            "/fast",
            get(|| async { axum::Json(serde_json::json!({ "ok": true })) }),
        )
        .layer(middleware::from_fn(crate::daemon::http::trace_http_request));
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });

    let client = reqwest::Client::new();
    let slow_request = tokio::spawn({
        let client = client.clone();
        async move {
            let propagation_headers = {
                let parent_span = tracing::info_span!("monitor.http.client", otel.kind = "client");
                let _parent_guard = parent_span.enter();
                crate::telemetry::current_trace_headers()
            };
            let mut request = client.get(format!("http://{addr}/slow"));
            for (header, value) in &propagation_headers {
                request = request.header(header, value);
            }
            let response = request.send().await.expect("send slow request");
            assert_eq!(response.status(), reqwest::StatusCode::OK);
        }
    });

    slow_started.notified().await;

    let fast_response = client
        .get(format!("http://{addr}/fast"))
        .send()
        .await
        .expect("send fast request");
    assert_eq!(fast_response.status(), reqwest::StatusCode::OK);

    release_slow.notify_one();
    slow_request.await.expect("join slow request");

    server.abort();
    let _ = server.await;
    let _ = tracer_provider.force_flush();

    let spans = exporter.finished_spans();
    let slow_request_span = find_exported_span(&spans, "GET /slow");
    let fast_request_span = find_exported_span(&spans, "GET /fast");

    assert!(slow_request_span.parent_span_is_remote);
    assert_ne!(
        fast_request_span.span_context.trace_id(),
        slow_request_span.span_context.trace_id()
    );
    assert_ne!(
        fast_request_span.parent_span_id,
        slow_request_span.span_context.span_id()
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
