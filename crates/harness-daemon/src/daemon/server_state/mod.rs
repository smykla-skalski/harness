//! Daemon HTTP server state, generic over the database types it carries.
//!
//! [`DaemonHttpState`] and its satellite types live here instead of
//! `crate::daemon::http` so a module that only needs the state's shape - not
//! `crate::daemon::db`'s concrete types - can depend on this module instead of
//! all of `http`. `Db` and `AsyncDb` stay generic specifically so this module
//! never has to change in lockstep with `db`'s own internals; `crate::daemon::http`
//! is the one place that ties them down with `DaemonHttpState`/`AsyncDaemonDbSlot`
//! concrete type aliases.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::{Mutex as AsyncMutex, broadcast};

use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::http::companion::CompanionRouter;
use crate::daemon::protocol::StreamEvent;
use crate::daemon::remote_pairing::{
    RemotePairingEvent, RemotePairingRateLimiter, RemotePairingStatusRateLimiter,
};
use crate::daemon::state::DaemonManifest;

mod async_db_slot;
mod auth_mode;
mod managed_agent_locks;
mod recovery_snapshot_cache;
mod remote_limits;
mod replay_buffer;

pub use async_db_slot::AsyncDaemonDbSlot;
pub use auth_mode::DaemonHttpAuthMode;
pub use managed_agent_locks::{ManagedAgentMutationGuard, ManagedAgentMutationLocks};
pub use recovery_snapshot_cache::RecoverySnapshotCache;
pub use remote_limits::{RemoteRequestLimitConfig, RemoteRequestLimits};
pub use replay_buffer::{PreparedBroadcast, ReplayBuffer};

/// Daemon HTTP server state, generic over the synchronous and asynchronous
/// database handles it carries.
///
/// `crate::daemon::http::DaemonHttpState` is the concrete alias every route
/// handler, WebSocket relay, and service function names; `Db`/`AsyncDb` exist
/// only so this struct's shape does not have to move in lockstep with
/// `crate::daemon::db`.
pub struct DaemonHttpState<Db, AsyncDb> {
    pub token: String,
    pub auth_mode: DaemonHttpAuthMode,
    pub remote_domain: Option<String>,
    /// Companion service this daemon forwards a configured path subtree to.
    /// `None` leaves the router, the auth layer, and every response exactly as
    /// they are without companion routing.
    pub companion: Option<CompanionRouter>,
    pub remote_request_limits: Option<RemoteRequestLimits>,
    pub remote_pairing_limiter: Arc<Mutex<RemotePairingRateLimiter>>,
    pub remote_pairing_status_limiter: Arc<Mutex<RemotePairingStatusRateLimiter>>,
    pub sender: broadcast::Sender<StreamEvent>,
    /// Fan-out channel carrying events serialized once into a shared
    /// [`PreparedBroadcast`]. Connection relays and SSE streams subscribe here
    /// instead of re-serializing each event per subscriber.
    pub prepared_sender: broadcast::Sender<Arc<PreparedBroadcast>>,
    /// Pairing changes, for the remote clients holding `/v1/remote/ws` open.
    ///
    /// Its own channel rather than a variant on [`Self::sender`], which feeds
    /// `/v1/ws` and `/v1/stream`: those reach every `read` client, and a pairing
    /// change must reach only the credential that minted it.
    pub remote_pairing_events: broadcast::Sender<Arc<RemotePairingEvent>>,
    pub manifest: DaemonManifest,
    pub daemon_epoch: String,
    pub replay_buffer: Arc<Mutex<ReplayBuffer>>,
    pub db: Arc<OnceLock<Arc<Mutex<Db>>>>,
    pub async_db: AsyncDaemonDbSlot<AsyncDb>,
    pub db_path: Option<PathBuf>,
    pub codex_controller: CodexControllerHandle,
    pub agent_tui_manager: AgentTuiManagerHandle,
    pub acp_agent_manager: AcpAgentManagerHandle,
    pub managed_agent_mutation_locks: ManagedAgentMutationLocks,
    /// Single-flight cache for the global `sessions_updated` recovery snapshot.
    /// When many relays lag past the replay buffer at once they would each
    /// rebuild the same snapshot; holding this lock across the rebuild
    /// collapses the herd into one build per change generation.
    pub recovery_snapshot: Arc<AsyncMutex<RecoverySnapshotCache>>,
}

// Written by hand rather than `#[derive(Clone)]`: the derive would add
// `Db: Clone` and `AsyncDb: Clone` bounds, but every field holding one is
// behind an `Arc`, so cloning the state never needs to clone the database
// itself.
impl<Db, AsyncDb> Clone for DaemonHttpState<Db, AsyncDb> {
    fn clone(&self) -> Self {
        Self {
            token: self.token.clone(),
            auth_mode: self.auth_mode,
            remote_domain: self.remote_domain.clone(),
            companion: self.companion.clone(),
            remote_request_limits: self.remote_request_limits.clone(),
            remote_pairing_limiter: Arc::clone(&self.remote_pairing_limiter),
            remote_pairing_status_limiter: Arc::clone(&self.remote_pairing_status_limiter),
            sender: self.sender.clone(),
            prepared_sender: self.prepared_sender.clone(),
            remote_pairing_events: self.remote_pairing_events.clone(),
            manifest: self.manifest.clone(),
            daemon_epoch: self.daemon_epoch.clone(),
            replay_buffer: Arc::clone(&self.replay_buffer),
            db: Arc::clone(&self.db),
            async_db: self.async_db.clone(),
            db_path: self.db_path.clone(),
            codex_controller: self.codex_controller.clone(),
            agent_tui_manager: self.agent_tui_manager.clone(),
            acp_agent_manager: self.acp_agent_manager.clone(),
            managed_agent_mutation_locks: self.managed_agent_mutation_locks.clone(),
            recovery_snapshot: Arc::clone(&self.recovery_snapshot),
        }
    }
}
