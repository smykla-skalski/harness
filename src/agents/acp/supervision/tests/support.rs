use std::fs;
use std::path::Path;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

#[track_caller]
pub(super) fn ok<T, E: std::fmt::Debug>(result: Result<T, E>, context: &str) -> T {
    assert!(
        result.is_ok(),
        "{context}: unexpected Err({:?})",
        result.as_ref().err()
    );
    match result {
        Ok(value) => value,
        Err(error) => unreachable!("{context}: {error:?}"),
    }
}

pub(super) fn spawn_sleep_child() -> Child {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;

        let mut cmd = Command::new("sleep");
        cmd.arg("60");
        cmd.process_group(0);
        ok(cmd.spawn(), "spawn sleep")
    }
    #[cfg(not(unix))]
    {
        ok(
            Command::new("timeout").args(["/t", "60"]).spawn(),
            "spawn timeout",
        )
    }
}

#[cfg(unix)]
pub(super) fn wait_for_file_marker(path: &Path, marker: &str) {
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut found = false;
    while Instant::now() < deadline {
        if fs::read_to_string(path).is_ok_and(|content| content.contains(marker)) {
            found = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(found, "expected marker '{marker}' in {}", path.display());
}
