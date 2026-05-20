//! Daemon-side `OpenRouter` agent backend.
//!
//! Lives alongside [`crate::daemon::agent_acp`], [`crate::daemon::codex_controller`],
//! and [`crate::daemon::agent_tui`]. Unlike those backends, `OpenRouter` is just
//! an HTTPS endpoint, so the manager calls the API directly from inside the
//! daemon process via [`crate::agents::openrouter::OpenRouterClient`] instead
//! of spawning a child binary.
//!
//! Session lifecycle:
//! 1. [`OpenRouterAgentManagerHandle::start`] creates a session entry, kicks
//!    off the first turn, and returns a snapshot.
//! 2. Streaming SSE chunks fan out via the daemon's shared
//!    `broadcast::Sender<StreamEvent>` as `openrouter_chunk` events.
//! 3. [`OpenRouterAgentManagerHandle::prompt`] appends a user turn and starts
//!    another completion.
//! 4. [`OpenRouterAgentManagerHandle::cancel`] aborts the current turn task.
//! 5. Snapshots are queryable via [`OpenRouterAgentManagerHandle::get`] /
//!    [`OpenRouterAgentManagerHandle::list`].

pub mod manager;
pub mod snapshot;

pub use manager::{
    OpenRouterAgentManagerHandle, OpenRouterRunListResponse, OpenRouterStartRequest,
};
pub use snapshot::{OpenRouterRunSnapshot, OpenRouterRunStatus};
