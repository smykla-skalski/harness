use std::collections::BTreeMap;
use std::fmt;

use tracing::field::{Field, Visit};
use tracing::span::Record;
use tracing_subscriber::field::{MakeVisitor, RecordFields, VisitFmt, VisitOutput};
use tracing_subscriber::fmt::FormattedFields;
use tracing_subscriber::fmt::format::{self, FormatFields, Writer};

#[derive(Debug, Default)]
pub(crate) struct FilteredDefaultFields {
    _private: (),
}

impl FilteredDefaultFields {
    pub(crate) fn new() -> Self {
        Self { _private: () }
    }
}

impl<'writer> MakeVisitor<Writer<'writer>> for FilteredDefaultFields {
    type Visitor = FilteredDefaultVisitor<'writer>;

    fn make_visitor(&self, target: Writer<'writer>) -> Self::Visitor {
        FilteredDefaultVisitor {
            inner: format::DefaultVisitor::new(target, true),
        }
    }
}

#[derive(Debug)]
pub(crate) struct FilteredDefaultVisitor<'writer> {
    inner: format::DefaultVisitor<'writer>,
}

impl Visit for FilteredDefaultVisitor<'_> {
    fn record_str(&mut self, field: &Field, value: &str) {
        if should_hide_console_field(field.name()) {
            return;
        }
        self.inner.record_str(field, value);
    }

    fn record_error(&mut self, field: &Field, value: &(dyn std::error::Error + 'static)) {
        if should_hide_console_field(field.name()) {
            return;
        }
        self.inner.record_error(field, value);
    }

    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        if should_hide_console_field(field.name()) {
            return;
        }
        self.inner.record_debug(field, value);
    }
}

impl VisitOutput<fmt::Result> for FilteredDefaultVisitor<'_> {
    fn finish(self) -> fmt::Result {
        self.inner.finish()
    }
}

impl VisitFmt for FilteredDefaultVisitor<'_> {
    fn writer(&mut self) -> &mut dyn fmt::Write {
        self.inner.writer()
    }
}

#[derive(Debug, Default)]
pub(crate) struct FilteredJsonFields {
    _private: (),
}

impl FilteredJsonFields {
    pub(crate) fn new() -> Self {
        Self { _private: () }
    }
}

impl<'writer> FormatFields<'writer> for FilteredJsonFields {
    fn format_fields<R: RecordFields>(&self, writer: Writer<'writer>, fields: R) -> fmt::Result {
        let mut visitor = FilteredJsonVisitor::new(writer);
        fields.record(&mut visitor);
        visitor.finish()
    }

    fn add_fields(
        &self,
        current: &'writer mut FormattedFields<Self>,
        fields: &Record<'_>,
    ) -> fmt::Result {
        let values = if current.is_empty() {
            BTreeMap::new()
        } else {
            serde_json::from_str(current).map_err(|_| fmt::Error)?
        };
        current.fields.clear();
        let mut visitor = FilteredJsonVisitor::with_values(current.as_writer(), values);
        fields.record(&mut visitor);
        visitor.finish()
    }
}

#[derive(Debug)]
struct FilteredJsonVisitor<'writer> {
    values: BTreeMap<String, serde_json::Value>,
    writer: Writer<'writer>,
}

impl<'writer> FilteredJsonVisitor<'writer> {
    fn new(writer: Writer<'writer>) -> Self {
        Self {
            values: BTreeMap::new(),
            writer,
        }
    }

    fn with_values(writer: Writer<'writer>, values: BTreeMap<String, serde_json::Value>) -> Self {
        Self { values, writer }
    }

    fn insert(&mut self, field: &Field, value: serde_json::Value) {
        if should_hide_console_field(field.name()) {
            return;
        }
        let name = field
            .name()
            .strip_prefix("r#")
            .unwrap_or(field.name())
            .to_string();
        self.values.insert(name, value);
    }

    fn finish(self) -> fmt::Result {
        let serialized = serde_json::to_string(&self.values).map_err(|_| fmt::Error)?;
        let mut writer = self.writer;
        writer.write_str(&serialized)
    }
}

impl Visit for FilteredJsonVisitor<'_> {
    fn record_f64(&mut self, field: &Field, value: f64) {
        self.insert(field, serde_json::Value::from(value));
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.insert(field, serde_json::Value::from(value));
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.insert(field, serde_json::Value::from(value));
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.insert(field, serde_json::Value::from(value));
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        self.insert(field, serde_json::Value::from(value));
    }

    fn record_bytes(&mut self, field: &Field, value: &[u8]) {
        self.insert(field, serde_json::Value::from(format!("{value:?}")));
    }

    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        self.insert(field, serde_json::Value::from(format!("{value:?}")));
    }
}

fn should_hide_console_field(name: &str) -> bool {
    name == "trace_id"
        || name == "span_id"
        || name == "request_id"
        || name == "request.failed"
        || name.starts_with("otel.")
        || name.starts_with("db.")
        || name.starts_with("http.")
        || name.starts_with("network.protocol.")
        || name.starts_with("rpc.")
        || name.starts_with("server.")
        || name.starts_with("transport.")
        || name.starts_with("url.")
}

#[cfg(test)]
mod tests {
    use std::io;
    use std::sync::{Arc, Mutex};

    use tracing_subscriber::fmt::writer::MakeWriter;
    use tracing_subscriber::prelude::*;

    use super::*;

    #[test]
    fn observability_field_filter_targets_semconv_names() {
        assert!(should_hide_console_field("otel.name"));
        assert!(should_hide_console_field("http.route"));
        assert!(should_hide_console_field("db.system"));
        assert!(should_hide_console_field("trace_id"));
        assert!(should_hide_console_field("request_id"));
        assert!(!should_hide_console_field("duration_ms"));
        assert!(!should_hide_console_field("http_route"));
    }

    #[test]
    fn text_formatter_hides_observability_fields() {
        let output = capture_text_logs(|| {
            let span = tracing::info_span!(
                "harness.daemon.http.request",
                otel.name = "GET /v1/health",
                otel.kind = "server",
                request_id = "req-1",
                http_route = "/v1/health",
                "http.route" = "/v1/health",
                "rpc.system" = "harness-daemon",
                "url.path" = "/v1/health",
                trace_id = "deadbeef",
                duration_ms = 0_u64
            );
            let _guard = span.enter();
            tracing::info!("daemon request");
        });

        assert!(output.contains("http_route"));
        assert!(output.contains("duration_ms"));
        assert!(!output.contains("otel.name"));
        assert!(!output.contains("otel.kind"));
        assert!(!output.contains("http.route"));
        assert!(!output.contains("request_id"));
        assert!(!output.contains("rpc.system"));
        assert!(!output.contains("url.path"));
        assert!(!output.contains("trace_id"));
    }

    #[test]
    fn json_formatter_hides_observability_fields() {
        let output = capture_json_logs(|| {
            let span = tracing::info_span!(
                "daemon.websocket.rpc",
                otel.name = "session.subscribe",
                otel.kind = "server",
                request_id = "req-2",
                duration_ms = 7_u64,
                "rpc.system" = "harness-daemon",
                "transport.kind" = "websocket",
                trace_id = "feedface"
            );
            let _guard = span.enter();
            tracing::info!("broadcast event sent");
        });

        assert!(output.contains("\"duration_ms\":7"));
        assert!(!output.contains("otel.name"));
        assert!(!output.contains("otel.kind"));
        assert!(!output.contains("request_id"));
        assert!(!output.contains("rpc.system"));
        assert!(!output.contains("transport.kind"));
        assert!(!output.contains("trace_id"));
    }

    fn capture_text_logs(action: impl FnOnce()) -> String {
        let output = SharedOutput::default();
        let subscriber = tracing_subscriber::registry().with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_target(false)
                .fmt_fields(FilteredDefaultFields::new())
                .with_writer(output.clone()),
        );

        tracing::subscriber::with_default(subscriber, action);
        output.contents()
    }

    fn capture_json_logs(action: impl FnOnce()) -> String {
        let output = SharedOutput::default();
        let subscriber = tracing_subscriber::registry().with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_target(false)
                .json()
                .fmt_fields(FilteredJsonFields::new())
                .with_writer(output.clone()),
        );

        tracing::subscriber::with_default(subscriber, action);
        output.contents()
    }

    #[derive(Clone, Default)]
    struct SharedOutput(Arc<Mutex<Vec<u8>>>);

    impl SharedOutput {
        fn contents(&self) -> String {
            String::from_utf8(self.0.lock().expect("buffer lock").clone()).expect("utf8 output")
        }
    }

    impl<'a> MakeWriter<'a> for SharedOutput {
        type Writer = SharedOutputWriter;

        fn make_writer(&'a self) -> Self::Writer {
            SharedOutputWriter(Arc::clone(&self.0))
        }
    }

    struct SharedOutputWriter(Arc<Mutex<Vec<u8>>>);

    impl io::Write for SharedOutputWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0.lock().expect("buffer lock").extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
}
