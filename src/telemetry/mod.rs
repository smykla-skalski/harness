mod config;
mod guard;
mod metrics;
mod profiler;
mod providers;
mod subscriber;

#[cfg(test)]
use std::sync::{Mutex, MutexGuard, OnceLock};

pub use config::{
    DEFAULT_OTLP_GRPC_ENDPOINT, DEFAULT_OTLP_HTTP_ENDPOINT, ExportProtocol,
    ResolvedTelemetryConfig, RuntimeService, SharedObservabilityConfig, TelemetryConfigSource,
    resolve_telemetry_config, runtime_service_from_args, runtime_service_from_current_process,
    shared_config_path,
};
pub use metrics::{
    TelemetryBaggage, apply_current_baggage_to_span, apply_parent_context_from_headers,
    apply_parent_context_from_text_map, current_trace_headers, current_trace_id,
    install_text_map_propagator, record_daemon_client_metrics, record_daemon_db_health_counts,
    record_daemon_db_operation_metrics, record_daemon_db_pool_state, record_daemon_http_metrics,
    record_hook_metrics, with_active_baggage,
};
pub use profiler::DaemonProfiler;
pub use guard::TelemetryGuard;
pub use subscriber::init_tracing_subscriber;

#[cfg(test)]
pub(crate) fn telemetry_test_guard() -> MutexGuard<'static, ()> {
    static GUARD: OnceLock<Mutex<()>> = OnceLock::new();
    GUARD
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|error| error.into_inner())
}
