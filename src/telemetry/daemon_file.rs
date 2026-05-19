use std::io;

use tracing::Subscriber;
use tracing_subscriber::Layer;
use tracing_subscriber::fmt;
use tracing_subscriber::fmt::time::ChronoUtc;
use tracing_subscriber::fmt::writer::MakeWriter;
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
    if service != RuntimeService::Daemon {
        return None;
    }

    match (use_json_format, show_observability_fields) {
        (true, true) => Some(Box::new(fmt::layer().json().with_writer(DaemonLogWriter))),
        (true, false) => Some(Box::new(
            fmt::layer()
                .json()
                .fmt_fields(FilteredJsonFields::new())
                .with_writer(DaemonLogWriter),
        )),
        (false, true) => Some(Box::new(
            fmt::layer()
                .with_writer(DaemonLogWriter)
                .with_target(false)
                .with_timer(ChronoUtc::rfc_3339()),
        )),
        (false, false) => Some(Box::new(
            fmt::layer()
                .fmt_fields(FilteredDefaultFields::new())
                .with_writer(DaemonLogWriter)
                .with_target(false)
                .with_timer(ChronoUtc::rfc_3339()),
        )),
    }
}

#[derive(Debug, Clone, Copy)]
struct DaemonLogWriter;

impl<'writer> MakeWriter<'writer> for DaemonLogWriter {
    type Writer = DaemonLogFile;

    fn make_writer(&'writer self) -> Self::Writer {
        DaemonLogFile::open()
    }
}

enum DaemonLogFile {
    File(fs_err::File),
    Sink(io::Sink),
}

impl DaemonLogFile {
    fn open() -> Self {
        let path = crate::daemon::state::log_path();
        if crate::daemon::state::ensure_daemon_dirs().is_ok()
            && let Ok(file) = fs_err::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
        {
            return Self::File(file);
        }

        Self::Sink(io::sink())
    }
}

impl io::Write for DaemonLogFile {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Self::File(file) => file.write(buf),
            Self::Sink(sink) => sink.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::File(file) => file.flush(),
            Self::Sink(sink) => sink.flush(),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write as _;

    use tempfile::tempdir;

    use super::*;
    use crate::daemon::state::ScopedDaemonRootOverride;

    #[test]
    fn daemon_writer_appends_to_daemon_log_path() {
        let temp = tempdir().expect("tempdir");
        let _root = ScopedDaemonRootOverride::set(Some(temp.path().to_path_buf()));

        writeln!(DaemonLogFile::open(), "daemon file smoke").expect("write daemon log");

        let content = fs_err::read_to_string(temp.path().join("daemon.log")).expect("read log");
        assert!(content.contains("daemon file smoke"));
    }
}
