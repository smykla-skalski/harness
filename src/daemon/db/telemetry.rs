use std::future::Future;
use std::path::Path;
use std::time::Instant;

use tracing::Instrument as _;
use tracing::field::{Empty, display};

use crate::errors::CliError;
use crate::telemetry::{apply_current_baggage_to_span, record_daemon_db_operation_metrics};

pub(crate) fn trace_sync_db_operation<T, F>(
    operation: &str,
    access: &str,
    db_path: Option<&Path>,
    work: F,
) -> Result<T, CliError>
where
    F: FnOnce() -> Result<T, CliError>,
{
    let span = db_operation_span(operation, "sync", access, db_path);
    let _guard = span.enter();
    let started_at = Instant::now();
    let result = work();
    finish_db_operation(
        operation, "sync", access, db_path, started_at, &span, &result,
    );
    result
}

pub(crate) async fn trace_async_db_operation<T, F, Fut>(
    operation: &str,
    access: &str,
    db_path: Option<&Path>,
    work: F,
) -> Result<T, CliError>
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<T, CliError>>,
{
    let span = db_operation_span(operation, "async", access, db_path);
    let started_at = Instant::now();
    let result = work().instrument(span.clone()).await;
    finish_db_operation(
        operation, "async", access, db_path, started_at, &span, &result,
    );
    result
}

fn db_operation_span(
    operation: &str,
    engine: &str,
    access: &str,
    db_path: Option<&Path>,
) -> tracing::Span {
    let otel_name = format!("daemon.db.{engine}.{operation}");
    let db_file = db_path
        .and_then(Path::file_name)
        .and_then(|file_name| file_name.to_str())
        .unwrap_or("memory");
    let span = tracing::info_span!(
        "harness.daemon.db.operation",
        otel.name = %otel_name,
        otel.kind = "client",
        "db.system" = "sqlite",
        "db.operation.name" = %operation,
        "db.access" = %access,
        "db.engine" = %engine,
        "db.file" = %db_file,
        duration_ms = Empty,
        error = Empty,
        error_message = Empty
    );
    apply_current_baggage_to_span(&span);
    span
}

fn finish_db_operation<T>(
    operation: &str,
    engine: &str,
    access: &str,
    db_path: Option<&Path>,
    started_at: Instant,
    span: &tracing::Span,
    result: &Result<T, CliError>,
) {
    let duration_ms = u64::try_from(started_at.elapsed().as_millis()).unwrap_or(u64::MAX);
    let is_error = result.is_err();
    let is_busy = result.as_ref().err().is_some_and(error_is_busy);

    span.record("duration_ms", display(duration_ms));
    span.record("error", display(is_error));
    if let Err(error) = result {
        span.record("error_message", display(error));
    }

    record_daemon_db_operation_metrics(
        operation,
        engine,
        access,
        duration_ms,
        is_error,
        is_busy,
        db_path,
    );
}

fn error_is_busy(error: &CliError) -> bool {
    let detail = error.to_string().to_ascii_lowercase();
    detail.contains("database is locked")
        || detail.contains("database schema is locked")
        || detail.contains("database busy")
        || detail.contains("busy timeout")
}
