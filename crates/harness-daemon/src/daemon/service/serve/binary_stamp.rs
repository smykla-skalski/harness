use std::env as std_env;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;

use super::{Duration, Path, state};

pub(super) fn current_binary_stamp() -> Option<state::DaemonBinaryStamp> {
    let helper_path = current_binary_path()?;
    let metadata = current_binary_metadata(&helper_path)?;
    let modification_time_interval_since_1970 = metadata_modification_time(&metadata)?;

    Some(state::DaemonBinaryStamp {
        helper_path: helper_path.display().to_string(),
        device_identifier: metadata.dev(),
        inode: metadata.ino(),
        file_size: metadata.size(),
        modification_time_interval_since_1970,
    })
}

fn current_binary_path() -> Option<PathBuf> {
    match std_env::current_exe() {
        Ok(path) => Some(path),
        Err(error) => log_current_binary_path_error(&error),
    }
}

fn current_binary_metadata(helper_path: &Path) -> Option<fs::Metadata> {
    match fs::metadata(helper_path) {
        Ok(metadata) => Some(metadata),
        Err(error) => log_current_binary_metadata_error(helper_path, &error),
    }
}

fn metadata_modification_time(metadata: &fs::Metadata) -> Option<f64> {
    let seconds = metadata_mtime_seconds(metadata)?;
    let nanos = metadata_mtime_nanos(metadata)?;
    Some(Duration::new(seconds, nanos).as_secs_f64())
}

fn metadata_mtime_seconds(metadata: &fs::Metadata) -> Option<u64> {
    match u64::try_from(metadata.mtime()) {
        Ok(seconds) => Some(seconds),
        Err(_) => log_negative_mtime(metadata.mtime()),
    }
}

fn metadata_mtime_nanos(metadata: &fs::Metadata) -> Option<u32> {
    match u32::try_from(metadata.mtime_nsec()) {
        Ok(nanos) => Some(nanos),
        Err(_) => log_invalid_mtime_nanos(metadata.mtime_nsec()),
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_current_binary_path_error(error: &io::Error) -> Option<PathBuf> {
    tracing::warn!(%error, "failed to resolve current daemon binary path");
    None
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_current_binary_metadata_error(
    helper_path: &Path,
    error: &io::Error,
) -> Option<fs::Metadata> {
    tracing::warn!(
        path = %helper_path.display(),
        %error,
        "failed to stat current daemon binary"
    );
    None
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_negative_mtime(seconds: i64) -> Option<u64> {
    tracing::warn!(
        seconds,
        "current daemon binary has a negative modification timestamp"
    );
    None
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_invalid_mtime_nanos(nanos: i64) -> Option<u32> {
    tracing::warn!(
        nanos,
        "current daemon binary has an invalid nanosecond timestamp"
    );
    None
}
