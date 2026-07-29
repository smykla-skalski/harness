mod bootstrap;
mod capabilities;
mod pre_compact;
mod secrets;
pub(crate) mod services;
mod session;
// `wrapper` now lives in `harness-hooks` (both this binary and `harness-hook`
// depend on it directly instead of `harness-hook` `#[path]`-mirroring this
// crate's source); this keeps `crate::setup::wrapper` a stable path for the
// existing call sites in bootstrap, daemon agent-tui spawn, and doctor.
pub(crate) use harness_hooks::wrapper;

pub use bootstrap::BootstrapArgs;
pub use bootstrap::bootstrap;
pub use capabilities::{CapabilitiesArgs, capabilities};
pub use pre_compact::PreCompactArgs;
pub use pre_compact::pre_compact;
pub use secrets::{SecretsArgs, SecretsCommand};
pub use session::{SessionStartArgs, SessionStopArgs};
pub use session::{session_start, session_stop};
