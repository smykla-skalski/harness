use crate::errors::{CliError, CliErrorKind};

/// Initialize the canonical tracing, logging, metrics, and OTLP stack.
///
/// # Errors
/// Returns an error when telemetry configuration or subscriber setup fails.
pub fn init_tracing() -> Result<harness_telemetry::TelemetryGuard, CliError> {
    harness_telemetry::init_tracing_subscriber_for(harness_telemetry::RuntimeService::Mcp).map_err(
        |error| CliErrorKind::workflow_io(format!("initialize MCP telemetry: {error}")).into(),
    )
}
