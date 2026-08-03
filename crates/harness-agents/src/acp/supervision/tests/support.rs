use std::fmt;
use std::fs;
use std::ops::{Deref, DerefMut};
use std::path::Path;
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant};

#[track_caller]
pub(super) fn ok<T, E: fmt::Debug>(result: Result<T, E>, context: &str) -> T {
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

pub(super) struct TestChild(Child);

impl Deref for TestChild {
    type Target = Child;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl DerefMut for TestChild {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

impl Drop for TestChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

pub(super) fn spawn_sleep_child() -> TestChild {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;

        let mut cmd = Command::new("sleep");
        cmd.arg("60");
        cmd.process_group(0);
        TestChild(ok(cmd.spawn(), "spawn sleep"))
    }
    #[cfg(not(unix))]
    {
        TestChild(ok(
            Command::new("timeout").args(["/t", "60"]).spawn(),
            "spawn timeout",
        ))
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
        thread::sleep(Duration::from_millis(10));
    }
    assert!(found, "expected marker '{marker}' in {}", path.display());
}
