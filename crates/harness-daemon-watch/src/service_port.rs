use std::time::Duration;

use async_trait::async_trait;
use tokio::sync::broadcast::Sender;

use harness_kernel::errors::CliError;
use harness_protocol::daemon::StreamEvent;

/// What the watch loop needs from `service` on every tick, named here so
/// `watch` never depends on `service` directly - `service` is the one
/// naming `watch`, not the reverse.
#[async_trait]
pub trait WatchServicePort<Db, AsyncDb>: Send + Sync {
    fn liveness_refresh_ttl(&self) -> Duration;

    /// # Errors
    /// Returns an error when liveness reconciliation fails.
    fn reconcile_liveness(&self, db: Option<&Db>) -> Result<(), CliError>;
    async fn reconcile_liveness_async(&self, async_db: Option<&AsyncDb>) -> Result<(), CliError>;

    fn broadcast_sessions_updated(&self, sender: &Sender<StreamEvent>, db: Option<&Db>);
    fn broadcast_session_updated_core(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        db: Option<&Db>,
    );
    fn broadcast_session_extensions(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        db: Option<&Db>,
    );

    async fn broadcast_sessions_updated_async(
        &self,
        sender: &Sender<StreamEvent>,
        async_db: Option<&AsyncDb>,
    );
    async fn broadcast_session_updated_core_async(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        async_db: Option<&AsyncDb>,
    );
    async fn broadcast_session_extensions_async(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        async_db: Option<&AsyncDb>,
    );
}
