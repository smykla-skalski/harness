//! Daemon `SQLite` schema history: every versioned migration (`schema_v10`
//! through the current tip) and the shape-repair passes that recover a
//! database whose objects have drifted from what the current version
//! expects.
//!
//! The migration *runner* - `ensure_schema`, the pre-v10 inline migrations,
//! and the baseline `CREATE_SCHEMA` SQL - stays in `harness-daemon`'s own
//! `daemon::db` module. This crate holds the history the runner walks, not
//! the orchestration that walks it, so it builds and tests independently of
//! the daemon binary's much larger dependency tree.
//!
//! Every `run(conn: &Connection)` here is `pub` because `harness-daemon`'s
//! runner calls each one by version number as it steps a database forward.
//!
//! The raw migration SQL under `migrations/*.sql` stays physically inside
//! `harness-daemon` (`daemon/db/migrations/`), reached here through a
//! relative `include_str!`: `harness-daemon`'s own `async_bootstrap.rs` uses
//! `sqlx::migrate!` against that exact directory to reconcile the async
//! pool's migration ledger, and that macro needs the whole shipped set in
//! one place, including files this crate hasn't been written yet to cover.
// This crate's test tree moved wholesale out of `harness-daemon`, which
// exempts its own `cfg(test)` code from pedantic for the same reason: it
// never went through a pedantic pass, so running the full lint set surfaces
// a pile of pre-existing, test-only findings about test-code shape, not
// defects. Production code keeps the full, undiminished lint set.
#![cfg_attr(test, allow(clippy::pedantic, clippy::too_many_lines))]

pub use harness_kernel::errors::CliError;
use harness_kernel::errors::CliErrorKind;
pub use rusqlite::Connection;

pub(crate) fn db_error(detail: impl Into<std::borrow::Cow<'static, str>>) -> CliError {
    CliError::from(CliErrorKind::workflow_io(detail))
}

pub mod schema_repairs;
pub mod schema_repairs_admission;
pub mod schema_repairs_external_creates;
pub mod schema_repairs_reconciliation_cursors;
pub mod schema_repairs_remote_execution;
pub mod schema_repairs_remote_execution_objects;
pub mod schema_repairs_remote_execution_v45;
mod schema_repairs_shape_probes;
pub mod schema_repairs_triage;
pub mod schema_repairs_triage_override;
pub mod schema_repairs_wake_events;
pub mod schema_v10;
pub mod schema_v11;
pub mod schema_v12;
pub mod schema_v13;
pub mod schema_v14;
pub mod schema_v15;
pub mod schema_v16;
pub mod schema_v17;
pub mod schema_v18;
pub mod schema_v19;
pub mod schema_v20;
pub mod schema_v21;
pub mod schema_v22;
pub mod schema_v23;
pub mod schema_v24;
pub mod schema_v25;
pub mod schema_v26;
pub mod schema_v27;
pub mod schema_v28;
pub mod schema_v29;
pub mod schema_v30;
pub mod schema_v31;
pub mod schema_v32;
pub mod schema_v33;
pub mod schema_v34;
pub mod schema_v35;
pub mod schema_v36;
pub mod schema_v37;
pub mod schema_v38;
pub mod schema_v39;
pub mod schema_v40;
pub mod schema_v41;
pub mod schema_v42;
pub mod schema_v43;
pub mod schema_v44;
pub mod schema_v45;
pub mod schema_v46;
pub mod schema_v47;
pub mod schema_v48;
pub mod schema_v49;
pub mod schema_v50;
pub mod schema_v51;
pub mod schema_v52;
pub mod schema_v53;
pub mod schema_v54;
pub mod schema_v55;
pub mod schema_v56;
pub mod schema_v57;
pub mod schema_v58;
pub mod schema_v59;
pub mod schema_v60;
pub mod schema_v61;
pub mod schema_v62;
pub mod schema_v63;
pub mod schema_v64;
pub mod schema_v65;
pub mod schema_v66;
pub mod schema_v67;
pub mod schema_v68;
pub mod schema_v69;
