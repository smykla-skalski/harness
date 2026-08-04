use std::ffi::OsString;
use std::fs::OpenOptions;
use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use fs2::FileExt as _;

const DAEMON_LOG_FILE_BYTES: u64 = 8 * 1024 * 1024;
const DAEMON_LOG_ARCHIVE_COUNT: usize = 2;
const MAX_EVENT_BYTES: usize = 256 * 1024;
const DAEMON_LEGACY_REDIRECT_LOGS: [&str; 4] = [
    "daemon.stdout.log",
    "daemon.stderr.log",
    "launchd.stdout.log",
    "launchd.stderr.log",
];
const BRIDGE_LEGACY_REDIRECT_LOGS: [&str; 2] = ["bridge.stdout.log", "bridge.stderr.log"];
static DAEMON_LOG_STATE: Mutex<retention::RetentionState> =
    Mutex::new(retention::RetentionState::new());

#[cfg(test)]
mod process_lock_tests;
mod retention;
#[cfg(test)]
mod retention_tests;
#[cfg(test)]
mod rotation_tests;
#[cfg(all(test, unix))]
mod symlink_tests;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum LogFormat {
    Json,
    Text,
}

pub(super) struct BoundedLogFile {
    path: PathBuf,
    event: EventBuffer,
    format: LogFormat,
    max_file_bytes: u64,
    archive_count: usize,
}

impl BoundedLogFile {
    pub(super) fn open(path: PathBuf, format: LogFormat) -> Self {
        Self::open_with_limits(
            path,
            DAEMON_LOG_FILE_BYTES,
            DAEMON_LOG_ARCHIVE_COUNT,
            format,
        )
    }

    fn open_with_limits(
        path: PathBuf,
        max_file_bytes: u64,
        archive_count: usize,
        format: LogFormat,
    ) -> Self {
        let event_limit = usize::try_from(max_file_bytes)
            .unwrap_or(usize::MAX)
            .min(MAX_EVENT_BYTES);
        Self {
            path,
            event: EventBuffer::new(event_limit),
            format,
            max_file_bytes,
            archive_count,
        }
    }

    fn commit(&mut self) -> io::Result<()> {
        let payload = self.event.take(self.format, self.max_file_bytes);
        if payload.is_empty() || self.max_file_bytes == 0 {
            return Ok(());
        }
        let result = self.commit_payload(&payload);
        if let Err(error) = &result {
            report_write_failure(&self.path, error);
        }
        result
    }

    fn commit_payload(&self, payload: &[u8]) -> io::Result<()> {
        let mut state = DAEMON_LOG_STATE
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let _file_lock = InterprocessLogLock::acquire(&self.path)?;
        let cleanup_warnings = state.prepare_path(
            &self.path,
            self.max_file_bytes,
            self.archive_count,
            self.format,
        )?;
        for warning in cleanup_warnings {
            let message = format!(
                "legacy log cleanup failed for {}: {}",
                warning.path.display(),
                warning.error
            );
            let event = diagnostic_event(self.format, "WARN", &message);
            append_event(
                &self.path,
                &event,
                self.max_file_bytes,
                self.archive_count,
                self.format,
            )?;
        }
        append_event(
            &self.path,
            payload,
            self.max_file_bytes,
            self.archive_count,
            self.format,
        )?;
        state.remember_current(&self.path, self.format)
    }
}

struct InterprocessLogLock(std::fs::File);

impl InterprocessLogLock {
    fn acquire(log_path: &Path) -> io::Result<Self> {
        let mut lock_path = OsString::from(log_path.as_os_str());
        lock_path.push(".lock");
        let mut options = OpenOptions::new();
        options.create(true).read(true).write(true);
        let file = open_no_follow(&mut options, Path::new(&lock_path))?;
        file.lock_exclusive()?;
        Ok(Self(file))
    }
}

impl Drop for InterprocessLogLock {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.0);
    }
}

impl Write for BoundedLogFile {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.event.push(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.commit()
    }
}

impl Drop for BoundedLogFile {
    fn drop(&mut self) {
        let _ = self.commit();
    }
}

struct EventBuffer {
    bytes: Vec<u8>,
    limit: usize,
    observed_bytes: u64,
}

impl EventBuffer {
    fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            limit,
            observed_bytes: 0,
        }
    }

    fn push(&mut self, bytes: &[u8]) {
        self.observed_bytes = self
            .observed_bytes
            .saturating_add(u64::try_from(bytes.len()).unwrap_or(u64::MAX));
        let remaining = self.limit.saturating_sub(self.bytes.len());
        self.bytes
            .extend_from_slice(&bytes[..bytes.len().min(remaining)]);
    }

    fn take(&mut self, format: LogFormat, max_file_bytes: u64) -> Vec<u8> {
        let observed_bytes = std::mem::take(&mut self.observed_bytes);
        if observed_bytes <= u64::try_from(self.bytes.len()).unwrap_or(u64::MAX) {
            return std::mem::take(&mut self.bytes);
        }
        self.bytes.clear();
        bounded_marker(
            format,
            "daemon log event omitted because it exceeded the per-event limit",
            observed_bytes,
            max_file_bytes,
        )
    }
}

fn append_event(
    path: &Path,
    payload: &[u8],
    max_file_bytes: u64,
    archive_count: usize,
    format: LogFormat,
) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let current_len = path.metadata().map_or(0, |metadata| metadata.len());
    let payload_len = u64::try_from(payload.len()).unwrap_or(u64::MAX);
    if current_len >= max_file_bytes || current_len.saturating_add(payload_len) > max_file_bytes {
        rotate_archives(path, max_file_bytes, archive_count, format)
            .or_else(|_| truncate_current(path))?;
    }
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    open_safe_append(&mut options, path)?.write_all(payload)
}

fn open_safe_append(options: &mut OpenOptions, path: &Path) -> io::Result<std::fs::File> {
    let file = open_no_follow(options, path)?;
    let metadata = file.metadata()?;
    if metadata.is_file() && !retention::has_multiple_links(&metadata) {
        return Ok(file);
    }
    drop(file);
    remove_if_exists(path)?;
    let mut replacement = OpenOptions::new();
    replacement.create_new(true).append(true);
    open_no_follow(&mut replacement, path)
}

fn rotate_archives(
    path: &Path,
    max_file_bytes: u64,
    archive_count: usize,
    format: LogFormat,
) -> io::Result<()> {
    if archive_count == 0 {
        return truncate_current(path).map(drop);
    }
    remove_if_exists(&archive_path(path, archive_count))?;
    for generation in (1..archive_count).rev() {
        rename_if_exists(
            &archive_path(path, generation),
            &archive_path(path, generation + 1),
        )?;
    }
    archive_current(path, &archive_path(path, 1), max_file_bytes, format)
}

fn archive_current(
    path: &Path,
    archive: &Path,
    max_file_bytes: u64,
    format: LogFormat,
) -> io::Result<()> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || retention::has_multiple_links(&metadata)
    {
        return remove_if_exists(path);
    }
    if metadata.len() <= max_file_bytes {
        return std::fs::rename(path, archive);
    }

    let marker = bounded_marker(
        format,
        "legacy daemon log omitted because it exceeded the file limit",
        metadata.len(),
        max_file_bytes,
    );
    let mut options = OpenOptions::new();
    options.create(true).write(true).truncate(true);
    let mut target = open_no_follow(&mut options, archive)?;
    target.write_all(&marker)?;
    remove_if_exists(path)
}

fn bounded_marker(
    format: LogFormat,
    message: &'static str,
    observed_bytes: u64,
    max_file_bytes: u64,
) -> Vec<u8> {
    let timestamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let mut marker = match format {
        LogFormat::Json => serde_json::to_vec(&serde_json::json!({
            "timestamp": timestamp,
            "level": "WARN",
            "fields": {
                "message": message,
                "observed_bytes": observed_bytes,
            },
            "target": "harness_telemetry",
        }))
        .unwrap_or_default(),
        LogFormat::Text => {
            format!("{timestamp} WARN {message} observed_bytes={observed_bytes}").into_bytes()
        }
    };
    marker.push(b'\n');
    if u64::try_from(marker.len()).unwrap_or(u64::MAX) > max_file_bytes {
        return Vec::new();
    }
    marker
}

pub(super) fn diagnostic_event(format: LogFormat, level: &str, message: &str) -> Vec<u8> {
    let timestamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let mut event = match format {
        LogFormat::Json => serde_json::to_vec(&serde_json::json!({
            "timestamp": timestamp,
            "level": level,
            "fields": { "message": message },
            "target": "harness_telemetry::fallback",
        }))
        .unwrap_or_default(),
        LogFormat::Text => {
            format!("{timestamp} {level} {}", message.replace(['\r', '\n'], " ")).into_bytes()
        }
    };
    event.push(b'\n');
    event
}

fn archive_path(path: &Path, generation: usize) -> PathBuf {
    let mut archived = OsString::from(path.as_os_str());
    archived.push(format!(".{generation}"));
    archived.into()
}

fn remove_if_exists(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn rename_if_exists(source: &Path, destination: &Path) -> io::Result<()> {
    match std::fs::rename(source, destination) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn truncate_current(path: &Path) -> io::Result<()> {
    let mut options = OpenOptions::new();
    options.create(true).write(true).truncate(true);
    open_no_follow(&mut options, path).map(drop)
}

fn open_no_follow(options: &mut OpenOptions, path: &Path) -> io::Result<std::fs::File> {
    #[cfg(unix)]
    options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK);
    options.open(path)
}

fn report_write_failure(path: &Path, error: &io::Error) {
    let _ = writeln!(
        io::stderr().lock(),
        "failed to write bounded daemon log {}: {error}",
        path.display()
    );
}
