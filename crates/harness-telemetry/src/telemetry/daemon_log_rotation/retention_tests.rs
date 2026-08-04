use std::io::Write as _;

use tempfile::tempdir;

use super::retention::RetentionState;
use super::{BoundedLogFile, LogFormat, append_event, archive_path};

fn write_with_state(
    state: &mut RetentionState,
    path: &std::path::Path,
    format: LogFormat,
    payload: &[u8],
) {
    state
        .prepare_path(path, 512, 2, format)
        .expect("prepare path");
    append_event(path, payload, 512, 2, format).expect("append event");
    state
        .remember_current(path, format)
        .expect("remember current generation");
}

#[test]
fn first_event_creates_the_runtime_log_directory_before_locking() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("nested/runtime/daemon.log");

    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Text)
        .write_all(b"first event")
        .expect("first event");

    assert_eq!(std::fs::read(path).expect("runtime log"), b"first event");
}

#[test]
fn overlapping_writers_revalidate_format_after_another_writer_rotates() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    let mut text_process = RetentionState::new();
    let mut json_process = RetentionState::new();

    write_with_state(
        &mut text_process,
        &path,
        LogFormat::Text,
        b"first text event\n",
    );
    write_with_state(
        &mut json_process,
        &path,
        LogFormat::Json,
        b"{\"message\":\"json event\"}\n",
    );
    write_with_state(
        &mut text_process,
        &path,
        LogFormat::Text,
        b"second text event\n",
    );

    assert_eq!(
        std::fs::read(&path).expect("current text log"),
        b"second text event\n"
    );
    serde_json::from_slice::<serde_json::Value>(
        &std::fs::read(archive_path(&path, 1)).expect("JSON archive"),
    )
    .expect("archive remains JSON only");
    assert_eq!(
        std::fs::read(archive_path(&path, 2)).expect("first text archive"),
        b"first text event\n"
    );
}

#[test]
fn failed_legacy_cleanup_is_recorded_without_blocking_the_current_log() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    let legacy_directory = root.path().join("daemon.stderr.log");
    std::fs::create_dir(&legacy_directory).expect("legacy directory");

    BoundedLogFile::open_with_limits(path.clone(), 1_024, 2, LogFormat::Text)
        .write_all(b"current event\n")
        .expect("bounded event");

    let current = std::fs::read_to_string(path).expect("current log");
    assert!(current.contains("legacy log cleanup failed"));
    assert!(current.contains("current event"));
    assert!(legacy_directory.is_dir());
}

#[test]
fn format_change_rotates_before_writing_new_records() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Text)
        .write_all(b"text event\n")
        .expect("text event");

    let json = serde_json::to_vec(&serde_json::json!({ "message": "json event" }))
        .expect("serialize event");
    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Json)
        .write_all(&json)
        .expect("JSON event");

    serde_json::from_slice::<serde_json::Value>(&std::fs::read(&path).expect("current log"))
        .expect("current generation must be JSON only");
    assert_eq!(
        std::fs::read(archive_path(&path, 1)).expect("text archive"),
        b"text event\n"
    );
}

#[test]
fn startup_bounds_existing_archives_and_removes_extra_generations() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    std::fs::write(archive_path(&path, 1), [b'x'; 600]).expect("oversized archive");
    std::fs::write(archive_path(&path, 2), b"retained").expect("second archive");
    std::fs::write(archive_path(&path, 3), [b'y'; 700]).expect("extra archive");
    std::fs::write(path.with_file_name("daemon.log.0"), [b'z'; 800]).expect("zero archive");
    std::fs::write(path.with_file_name("daemon.log.01"), [b'q'; 900])
        .expect("noncanonical archive");
    let overflowing = path.with_file_name("daemon.log.184467440737095516160");
    std::fs::write(&overflowing, [b'w'; 1_000]).expect("overflowing numeric archive");

    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Text)
        .write_all(b"current")
        .expect("current event");

    let first = std::fs::read_to_string(archive_path(&path, 1)).expect("bounded archive");
    assert!(first.contains("archive omitted"));
    assert!(first.len() <= 512);
    assert!(!archive_path(&path, 3).exists());
    assert!(!path.with_file_name("daemon.log.0").exists());
    assert!(!path.with_file_name("daemon.log.01").exists());
    assert!(!overflowing.exists());
}
