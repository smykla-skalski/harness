use super::*;

use std::sync::{Arc, Mutex};
use std::time::Duration as StdDuration;

use opentelemetry::Value as OTelValue;
use opentelemetry::global;
use opentelemetry::trace::TracerProvider as _;
use opentelemetry_sdk::error::OTelSdkResult;
use opentelemetry_sdk::propagation::TraceContextPropagator;
use opentelemetry_sdk::trace::{SdkTracerProvider, SpanData, SpanExporter};
use tempfile::tempdir;
use tracing_subscriber::prelude::*;

#[test]
fn daemon_serve_startup_groups_db_spans_under_startup_root() {
    let _guard = crate::telemetry::telemetry_test_guard();
    global::set_text_map_propagator(TraceContextPropagator::new());
    let exporter = TestSpanExporter::default();
    let tracer_provider = SdkTracerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    let tracer = tracer_provider.tracer("daemon-service-startup-tests");
    let subscriber =
        tracing_subscriber::registry().with(tracing_opentelemetry::layer().with_tracer(tracer));
    let _subscriber_guard = tracing::subscriber::set_default(subscriber);

    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("daemon-startup-telemetry"),
            || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("runtime");
                runtime.block_on(async {
                    let serve_task = tokio::spawn(async {
                        serve(DaemonServeConfig {
                            host: "127.0.0.1".into(),
                            port: 0,
                            ..DaemonServeConfig::default()
                        })
                        .await
                    });

                    tokio::time::timeout(StdDuration::from_secs(5), async {
                        loop {
                            if state::load_running_manifest().ok().flatten().is_some() {
                                break;
                            }
                            tokio::time::sleep(StdDuration::from_millis(50)).await;
                        }
                    })
                    .await
                    .expect("daemon manifest written");

                    request_shutdown().expect("request shutdown");
                    serve_task
                        .await
                        .expect("join daemon serve task")
                        .expect("daemon serve result");
                });
            },
        );
    });

    let _ = tracer_provider.force_flush();
    let spans = exporter.finished_spans();
    let startup_span = find_exported_span(&spans, "daemon.lifecycle.startup");
    assert!(
        startup_span.events.events.iter().any(|event| {
            event.name == "initializing daemon database schema"
        }),
        "startup span should capture sync DB initialization"
    );
    assert!(
        startup_span
            .events
            .events
            .iter()
            .any(|event| event.name == "async database pool ready"),
        "startup span should capture async DB readiness"
    );
    assert_eq!(
        span_string_attribute(startup_span, "daemon.phase").as_deref(),
        Some("startup")
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
