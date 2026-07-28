//! Wire contracts for the session domain.
//!
//! These describe session and managed-agent requests, so they carry the
//! domain's own types and belong beside it. The daemon re-exports them from
//! `crate::daemon::protocol`; nothing here may reach back into the daemon.

mod managed_agents;
mod session_requests;
mod summaries;

pub use managed_agents::*;
pub use session_requests::*;
pub use summaries::*;
