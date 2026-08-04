use std::io::Write as _;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use tempfile::tempdir;

use super::{BoundedLogFile, LogFormat, archive_path};

const LOG_PATH_ENV: &str = "HARNESS_TEST_BOUNDED_LOG_PATH";
const LOG_EVENT_ENV: &str = "HARNESS_TEST_BOUNDED_LOG_EVENT";
const START_PATH_ENV: &str = "HARNESS_TEST_BOUNDED_LOG_START";
const WRITER_TEST: &str =
    "telemetry::daemon_log_rotation::process_lock_tests::cross_process_writer_helper";

#[test]
fn cross_process_writer_helper() {
    let (Some(path), Some(event), Some(start)) = (
        std::env::var_os(LOG_PATH_ENV),
        std::env::var_os(LOG_EVENT_ENV),
        std::env::var_os(START_PATH_ENV),
    ) else {
        return;
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    while !std::path::Path::new(&start).exists() {
        assert!(Instant::now() < deadline, "start barrier timed out");
        thread::sleep(Duration::from_millis(1));
    }
    BoundedLogFile::open_with_limits(path.into(), 64, 2, LogFormat::Text)
        .write_all(event.as_encoded_bytes())
        .expect("cross-process event");
}

#[test]
fn rotation_is_serialized_across_processes() {
    let root = tempdir().expect("tempdir");
    let path = root.path().join("daemon.log");
    let start = root.path().join("start");
    let events = [
        "event-a-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
        "event-b-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
        "event-c-cccccccccccccccccccccccccccccccccccccccc\n",
    ];
    let current = std::env::current_exe().expect("current test binary");
    let mut children = events
        .iter()
        .map(|event| {
            Command::new(&current)
                .args(["--exact", WRITER_TEST, "--nocapture"])
                .env(LOG_PATH_ENV, &path)
                .env(LOG_EVENT_ENV, event)
                .env(START_PATH_ENV, &start)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawn writer process")
        })
        .collect::<Vec<_>>();
    std::fs::write(&start, b"go").expect("release writers");
    for child in &mut children {
        assert!(child.wait().expect("writer exit").success());
    }

    let mut retained = [path.clone(), archive_path(&path, 1), archive_path(&path, 2)]
        .map(|candidate| std::fs::read_to_string(candidate).expect("retained event"));
    retained.sort();
    let mut expected = events.map(str::to_owned);
    expected.sort();
    assert_eq!(retained, expected);
}
