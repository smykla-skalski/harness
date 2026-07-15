use std::fs::{File, OpenOptions};
use std::io;
use std::path::PathBuf;

use tracing::Subscriber;
use tracing_subscriber::Layer;
use tracing_subscriber::fmt;
use tracing_subscriber::fmt::time::ChronoUtc;
use tracing_subscriber::fmt::writer::MakeWriter;
use tracing_subscriber::registry::LookupSpan;

use crate::workspace::{harness_data_root, normalized_env_value};

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
    File(File),
    Sink(io::Sink),
}

impl DaemonLogFile {
    fn open() -> Self {
        let path = daemon_log_path();
        if let Some(parent) = path.parent()
            && std::fs::create_dir_all(parent).is_ok()
            && let Ok(file) = OpenOptions::new().create(true).append(true).open(path)
        {
            return Self::File(file);
        }
        Self::Sink(io::sink())
    }
}

impl io::Write for DaemonLogFile {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        match self {
            Self::File(file) => file.write(bytes),
            Self::Sink(sink) => sink.write(bytes),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::File(file) => file.flush(),
            Self::Sink(sink) => sink.flush(),
        }
    }
}

fn daemon_log_path() -> PathBuf {
    daemon_base_dir()
        .join(daemon_ownership())
        .join("daemon.log")
}

fn daemon_base_dir() -> PathBuf {
    if let Some(root) = normalized_env_value("HARNESS_DAEMON_DATA_HOME") {
        return PathBuf::from(root).join("harness").join("daemon");
    }
    if let Some(group_id) = normalized_env_value("HARNESS_APP_GROUP_ID") {
        return home_dir()
            .join("Library")
            .join("Group Containers")
            .join(group_id)
            .join("harness")
            .join("daemon");
    }
    harness_data_root().join("daemon")
}

fn daemon_ownership() -> &'static str {
    if normalized_env_value("HARNESS_DAEMON_OWNERSHIP")
        .is_some_and(|value| value.eq_ignore_ascii_case("external"))
    {
        "external"
    } else {
        "managed"
    }
}

fn home_dir() -> PathBuf {
    normalized_env_value("HARNESS_HOST_HOME")
        .map(PathBuf::from)
        .or_else(|| user_dirs::home_dir().ok())
        .or_else(|| normalized_env_value("HOME").map(PathBuf::from))
        .unwrap_or_else(std::env::temp_dir)
}
