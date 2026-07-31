use std::sync::{Mutex, OnceLock};

#[derive(Clone)]
pub(super) struct ReadOnlyLaunchTestOverride {
    pub(super) exact_head: String,
}

static READ_ONLY_LAUNCH_TEST_OVERRIDE: OnceLock<Mutex<Option<ReadOnlyLaunchTestOverride>>> =
    OnceLock::new();
static READ_ONLY_LAUNCH_TEST_SERIAL: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();

pub(in crate::daemon) async fn with_read_only_launch_test_override<T, Work>(
    exact_head: &str,
    work: Work,
) -> T
where
    Work: std::future::Future<Output = T>,
{
    let _serial = read_only_launch_test_serial().lock().await;
    *read_only_launch_test_override()
        .lock()
        .expect("read-only launch override lock") = Some(ReadOnlyLaunchTestOverride {
        exact_head: exact_head.into(),
    });
    let _reset = ReadOnlyLaunchTestOverrideReset;
    work.await
}

struct ReadOnlyLaunchTestOverrideReset;

impl Drop for ReadOnlyLaunchTestOverrideReset {
    fn drop(&mut self) {
        *read_only_launch_test_override()
            .lock()
            .expect("read-only launch override lock") = None;
    }
}

pub(super) fn read_only_launch_test_override() -> &'static Mutex<Option<ReadOnlyLaunchTestOverride>>
{
    READ_ONLY_LAUNCH_TEST_OVERRIDE.get_or_init(|| Mutex::new(None))
}

pub(super) fn read_only_launch_test_serial() -> &'static tokio::sync::Mutex<()> {
    READ_ONLY_LAUNCH_TEST_SERIAL.get_or_init(|| tokio::sync::Mutex::new(()))
}
