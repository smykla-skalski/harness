use std::io::Write as _;
use std::os::unix::fs::symlink;
use std::os::unix::net::UnixListener;

use tempfile::tempdir;

use super::{BoundedLogFile, LogFormat};

#[test]
fn legacy_cleanup_removes_symlink_without_touching_target() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    let target = root.path().join("valuable.txt");
    let legacy = root.path().join("daemon.stderr.log");
    std::fs::write(&target, b"keep me").expect("target file");
    symlink(&target, &legacy).expect("legacy log symlink");

    BoundedLogFile::open_with_limits(path, 512, 2, LogFormat::Text)
        .write_all(b"event")
        .expect("first bounded event");

    assert_eq!(std::fs::read(&target).expect("target contents"), b"keep me");
    assert!(std::fs::symlink_metadata(legacy).is_err());
}

#[test]
fn current_log_symlink_is_never_followed() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    let target = root.path().join("valuable.txt");
    std::fs::write(&target, b"keep me").expect("target file");
    symlink(&target, &path).expect("daemon log symlink");

    let mut writer = BoundedLogFile::open_with_limits(path, 512, 2, LogFormat::Text);
    writer.write_all(b"event").expect("buffer event");
    writer.flush().expect("replace unsafe log path");

    assert_eq!(std::fs::read(&target).expect("target contents"), b"keep me");
}

#[test]
fn current_log_hard_link_is_replaced_without_touching_target() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    let target = root.path().join("valuable.txt");
    std::fs::write(&target, b"keep me").expect("target file");
    std::fs::hard_link(&target, &path).expect("daemon log hard link");

    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Text)
        .write_all(b"event")
        .expect("replace unsafe log path");

    assert_eq!(std::fs::read(&target).expect("target contents"), b"keep me");
    assert_eq!(std::fs::read(path).expect("new log contents"), b"event");
}

#[test]
fn hard_link_replacement_after_initial_write_is_not_followed() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Text)
        .write_all(b"initial")
        .expect("initial event");
    std::fs::remove_file(&path).expect("remove current log");
    let target = root.path().join("valuable.txt");
    std::fs::write(&target, b"keep me").expect("target file");
    std::fs::hard_link(&target, &path).expect("replacement hard link");

    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Text)
        .write_all(b"replacement")
        .expect("replacement event");

    assert_eq!(std::fs::read(&target).expect("target contents"), b"keep me");
    assert_eq!(
        std::fs::read(path).expect("new log contents"),
        b"replacement"
    );
}

#[test]
fn socket_replacement_after_initial_write_cannot_block_logging() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Text)
        .write_all(b"initial")
        .expect("initial event");
    std::fs::remove_file(&path).expect("remove current log");
    let _listener = UnixListener::bind(&path).expect("replacement socket");

    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Text)
        .write_all(b"replacement")
        .expect("replace socket path");

    assert_eq!(
        std::fs::read(path).expect("new log contents"),
        b"replacement"
    );
}
