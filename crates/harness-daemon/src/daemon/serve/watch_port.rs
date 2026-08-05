use std::time::Duration;

use async_trait::async_trait;
use tokio::sync::broadcast::Sender;

use crate::daemon::db_handle::{AsyncDaemonDbHandle, DaemonDbOwnedHandle};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::service;
use crate::daemon::watch::WatchServicePort;
use harness_kernel::errors::CliError;

/// Forwards the watch loop's `service` needs to the real implementations.
/// Zero-sized: it exists only so `spawn_watch_loop` gets a `service`-shaped
/// port without `watch` naming `service` itself.
pub(super) struct DaemonWatchServicePort;

#[async_trait]
impl WatchServicePort<DaemonDbOwnedHandle, AsyncDaemonDbHandle> for DaemonWatchServicePort {
    fn liveness_refresh_ttl(&self) -> Duration {
        service::SESSION_LIVENESS_REFRESH_TTL
    }

    fn reconcile_liveness(&self, db: Option<&DaemonDbOwnedHandle>) -> Result<(), CliError> {
        service::reconcile_active_session_liveness_background(db)
    }

    async fn reconcile_liveness_async(
        &self,
        async_db: Option<&AsyncDaemonDbHandle>,
    ) -> Result<(), CliError> {
        service::reconcile_active_session_liveness_background_async(async_db).await
    }

    fn broadcast_sessions_updated(
        &self,
        sender: &Sender<StreamEvent>,
        db: Option<&DaemonDbOwnedHandle>,
    ) {
        service::broadcast_sessions_updated(sender, db);
    }

    fn broadcast_session_updated_core(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        db: Option<&DaemonDbOwnedHandle>,
    ) {
        service::broadcast_session_updated_core(sender, session_id, db);
    }

    fn broadcast_session_extensions(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        db: Option<&DaemonDbOwnedHandle>,
    ) {
        service::broadcast_session_extensions(sender, session_id, db);
    }

    async fn broadcast_sessions_updated_async(
        &self,
        sender: &Sender<StreamEvent>,
        async_db: Option<&AsyncDaemonDbHandle>,
    ) {
        service::broadcast_sessions_updated_async(sender, async_db).await;
    }

    async fn broadcast_session_updated_core_async(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        async_db: Option<&AsyncDaemonDbHandle>,
    ) {
        service::broadcast_session_updated_core_async(sender, session_id, async_db).await;
    }

    async fn broadcast_session_extensions_async(
        &self,
        sender: &Sender<StreamEvent>,
        session_id: &str,
        async_db: Option<&AsyncDaemonDbHandle>,
    ) {
        service::broadcast_session_extensions_async(sender, session_id, async_db).await;
    }
}
