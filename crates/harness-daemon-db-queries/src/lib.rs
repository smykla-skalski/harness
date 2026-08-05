//! Session, timeline, diagnostics, audit, and change-tracking query traits
//! for [`harness_daemon_db_core::DaemonDb`]/[`harness_daemon_db_core::AsyncDaemonDb`],
//! extracted from `harness-daemon` so `service`, `http`, and `websocket`
//! can reach the database without depending on `harness-daemon` itself.
//!
//! Every trait here is implemented directly on the db-core types, never on
//! `harness-daemon`'s own `DaemonDbOwnedHandle`/`AsyncDaemonDbHandle`
//! wrappers - those wrappers exist only to let `harness-daemon` implement
//! traits owned by *other* sibling crates (see that type's own doc comment),
//! which is a different problem than this crate solves.

mod async_change_tracking;
mod async_diagnostics;
mod async_signal_writes;
mod change_tracking;
mod diagnostics;
mod signals;

pub use async_change_tracking::AsyncChangeTrackingQueries;
pub use async_diagnostics::AsyncDiagnosticsQueries;
pub use async_signal_writes::AsyncSignalIndexQueries;
pub use change_tracking::{ChangeTrackingQueries, LOAD_CHANGE_TRACKING_SQL};
pub use diagnostics::{DaemonDbDiagnostics, import_daemon_events};
pub use signals::{SignalIndexQueries, derive_effective_signal_status};
