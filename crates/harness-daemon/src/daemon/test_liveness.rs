use std::time::Duration;

/// How long a daemon test waits before calling an operation hung.
///
/// Only a genuine hang reaches it. Assertions wait for the state they expect
/// rather than for a duration to elapse, so this bound never decides an outcome:
/// it exists because nextest's default profile sets no global timeout, and a
/// hung test would otherwise block the whole run. A bound tight enough to be
/// reachable by slow-but-working work is a flake, not a backstop, which is what
/// the 250ms accept deadline in the remote-transport probe servers turned out to
/// be under suite load.
pub(crate) const LIVENESS: Duration = Duration::from_secs(30);
