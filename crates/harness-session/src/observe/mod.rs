mod once;
mod predicates;
mod scan;
mod support;
mod watch;

#[cfg(test)]
mod conflict_tests;
#[cfg(test)]
mod incremental_tests;
#[cfg(test)]
mod observe_tests;
#[cfg(test)]
mod test_support;

pub use once::execute_session_observe;
// `pub`, not `pub(crate)`: the root crate's `daemon::service::observe_*`
// modules call all of these directly across the crate boundary.
#[cfg(feature = "daemon-runtime")]
pub use once::run_session_observe;
#[cfg(feature = "daemon-runtime")]
pub use predicates::{should_observe, should_tick_liveness};
#[cfg(feature = "daemon-runtime")]
pub use scan::{AgentLogTailState, scan_all_agents, scan_all_agents_incremental};
#[cfg(feature = "daemon-runtime")]
pub use support::persist_observer_snapshot;
pub use support::task_severity_for_issue;
pub use watch::{execute_session_watch, execute_session_watch_async};
