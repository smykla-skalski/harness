use std::io::Write as _;
use std::thread;

use tempfile::tempdir;

use super::{BoundedLogFile, LogFormat, archive_path};

#[test]
fn event_is_not_split_across_rotation() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    BoundedLogFile::open_with_limits(path.clone(), 8, 2, LogFormat::Text)
        .write_all(b"123456")
        .expect("initial event");
    BoundedLogFile::open_with_limits(path.clone(), 8, 2, LogFormat::Text)
        .write_all(b"next")
        .expect("rotated event");

    assert_eq!(std::fs::read(&path).expect("current log"), b"next");
    assert_eq!(
        std::fs::read(archive_path(&path, 1)).expect("first archive"),
        b"123456"
    );
}

#[test]
fn generations_cannot_exceed_total_retention() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    for event in [b"12345678", b"abcdefgh", b"ABCDEFGH", b"87654321"] {
        BoundedLogFile::open_with_limits(path.clone(), 8, 2, LogFormat::Text)
            .write_all(event)
            .expect("write event");
    }

    let retained = [path.clone(), archive_path(&path, 1), archive_path(&path, 2)]
        .into_iter()
        .map(|candidate| std::fs::read(candidate).expect("retained log generation"))
        .collect::<Vec<_>>();
    assert!(retained.iter().all(|generation| generation.len() <= 8));
    assert_eq!(retained.iter().map(Vec::len).sum::<usize>(), 24);
    assert_eq!(retained[0], b"87654321");
}

#[test]
fn oversized_text_event_becomes_a_valid_marker() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Text)
        .write_all(&[b'x'; 600])
        .expect("oversized event");

    let retained = std::fs::read_to_string(&path).expect("utf8 marker");
    assert!(retained.contains("daemon log event omitted"));
    assert!(retained.contains("observed_bytes=600"));
    assert!(retained.len() <= 512);
    assert!(!archive_path(&path, 1).exists());
}

#[test]
fn oversized_json_event_becomes_a_valid_record() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Json)
        .write_all(&[b'x'; 600])
        .expect("oversized event");

    let retained = std::fs::read_to_string(&path).expect("utf8 marker");
    let marker: serde_json::Value = serde_json::from_str(retained.trim()).expect("json marker");
    assert_eq!(marker["level"], "WARN");
    assert_eq!(marker["fields"]["observed_bytes"], 600);
    assert!(retained.len() <= 512);
}

#[test]
fn concurrent_events_remain_complete() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    let handles = (0..16)
        .map(|index| {
            let path = path.clone();
            thread::spawn(move || {
                let line = format!("event-{index}\n");
                BoundedLogFile::open_with_limits(path, 4_096, 2, LogFormat::Text)
                    .write_all(line.as_bytes())
                    .expect("concurrent event");
            })
        })
        .collect::<Vec<_>>();
    for handle in handles {
        handle.join().expect("writer thread");
    }

    let contents = std::fs::read_to_string(path).expect("current log");
    let mut lines = contents.lines().collect::<Vec<_>>();
    lines.sort_unstable();
    assert_eq!(lines.len(), 16);
    for index in 0..16 {
        assert!(
            lines
                .binary_search(&format!("event-{index}").as_str())
                .is_ok()
        );
    }
}

#[test]
fn first_event_truncates_regular_legacy_redirect_logs() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    for name in super::DAEMON_LEGACY_REDIRECT_LOGS {
        std::fs::write(root.path().join(name), b"unbounded legacy output")
            .expect("legacy redirect log");
    }

    BoundedLogFile::open_with_limits(path, 512, 2, LogFormat::Text)
        .write_all(b"event")
        .expect("first bounded event");

    for name in super::DAEMON_LEGACY_REDIRECT_LOGS {
        assert_eq!(
            std::fs::metadata(root.path().join(name))
                .expect("legacy redirect metadata")
                .len(),
            0
        );
    }
}

#[test]
fn legacy_oversized_text_log_becomes_a_marker() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    std::fs::write(&path, [b'x'; 600]).expect("legacy log");

    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Text)
        .write_all(b"new")
        .expect("bounded append");

    assert_eq!(std::fs::read(&path).expect("current log"), b"new");
    let archived = std::fs::read_to_string(archive_path(&path, 1)).expect("utf8 archive marker");
    assert!(archived.contains("legacy daemon log omitted"));
    assert!(archived.contains("observed_bytes=600"));
}

#[test]
fn legacy_oversized_json_log_becomes_a_valid_record() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    std::fs::write(&path, [b'x'; 600]).expect("legacy log");

    BoundedLogFile::open_with_limits(path.clone(), 512, 2, LogFormat::Json)
        .write_all(b"new")
        .expect("bounded append");

    let archived = std::fs::read_to_string(archive_path(&path, 1)).expect("utf8 archive marker");
    let marker: serde_json::Value =
        serde_json::from_str(archived.trim()).expect("json archive marker");
    assert_eq!(marker["level"], "WARN");
    assert_eq!(marker["fields"]["observed_bytes"], 600);
}
