use std::io;

use tracing::Subscriber;
use tracing_subscriber::Layer;
use tracing_subscriber::fmt;
use tracing_subscriber::fmt::time::ChronoUtc;
use tracing_subscriber::registry::LookupSpan;

use super::config::RuntimeService;
use super::console_fields::{FilteredDefaultFields, FilteredJsonFields};

pub(super) fn layer<S>(
    service: RuntimeService,
    use_json_format: bool,
    show_observability_fields: bool,
) -> Option<Box<dyn Layer<S> + Send + Sync + 'static>>
where
    S: Subscriber + for<'span> LookupSpan<'span>,
{
    if matches!(service, RuntimeService::Daemon | RuntimeService::Bridge) {
        return None;
    }

    match (use_json_format, show_observability_fields) {
        (true, true) => Some(Box::new(fmt::layer().json().with_writer(io::stderr))),
        (true, false) => Some(Box::new(
            fmt::layer()
                .json()
                .fmt_fields(FilteredJsonFields::new())
                .with_writer(io::stderr),
        )),
        (false, true) => Some(Box::new(
            fmt::layer()
                .with_writer(io::stderr)
                .with_target(false)
                .with_timer(ChronoUtc::rfc_3339()),
        )),
        (false, false) => Some(Box::new(
            fmt::layer()
                .fmt_fields(FilteredDefaultFields::new())
                .with_writer(io::stderr)
                .with_target(false)
                .with_timer(ChronoUtc::rfc_3339()),
        )),
    }
}

#[cfg(test)]
mod tests {
    use tracing_subscriber::Registry;

    use super::layer;
    use crate::telemetry::RuntimeService;

    #[test]
    fn long_lived_services_use_only_their_bounded_file_layer() {
        assert!(layer::<Registry>(RuntimeService::Daemon, false, true).is_none());
        assert!(layer::<Registry>(RuntimeService::Daemon, true, true).is_none());
        assert!(layer::<Registry>(RuntimeService::Bridge, false, true).is_none());
        assert!(layer::<Registry>(RuntimeService::Bridge, true, true).is_none());
    }

    #[test]
    fn interactive_services_keep_stderr_output() {
        assert!(layer::<Registry>(RuntimeService::Cli, false, false).is_some());
        assert!(layer::<Registry>(RuntimeService::Hook, true, true).is_some());
    }
}
