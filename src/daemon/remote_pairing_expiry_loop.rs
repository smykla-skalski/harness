use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};

use super::db::AsyncDaemonDb;
use crate::workspace::utc_now;

const REMOTE_PAIRING_EXPIRY_INTERVAL: Duration = Duration::from_secs(30);

pub(crate) fn spawn_remote_pairing_expiry_loop(
    db: Arc<AsyncDaemonDb>,
    shutdown_rx: watch::Receiver<bool>,
) -> JoinHandle<()> {
    tokio::spawn(run_remote_pairing_expiry_loop(db, shutdown_rx))
}

async fn run_remote_pairing_expiry_loop(
    db: Arc<AsyncDaemonDb>,
    mut shutdown_rx: watch::Receiver<bool>,
) {
    let mut ticker = interval(REMOTE_PAIRING_EXPIRY_INTERVAL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            () = wait_for_shutdown(&mut shutdown_rx) => break,
            _ = ticker.tick() => record_expired_pairings(&db).await,
        }
    }
}

async fn wait_for_shutdown(shutdown_rx: &mut watch::Receiver<bool>) {
    if *shutdown_rx.borrow() {
        return;
    }
    while shutdown_rx.changed().await.is_ok() {
        if *shutdown_rx.borrow() {
            break;
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
async fn record_expired_pairings(db: &AsyncDaemonDb) {
    match db.record_expired_remote_pairings(&utc_now()).await {
        Ok(0) => {}
        Ok(expired) => tracing::info!(expired, "recorded remote pairing expirations"),
        Err(error) => tracing::error!(%error, "record remote pairing expirations"),
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tempfile::tempdir;

    use super::*;
    use crate::daemon::db::DaemonDb;
    use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
    use crate::daemon::remote_pairing::{RemotePairingCode, RemotePairingRecord};

    #[tokio::test]
    async fn remote_pairing_expiry_loop_records_unused_expiration_once() {
        let temp = tempdir().expect("create pairing expiry tempdir");
        let db_path = temp.path().join("harness.db");
        seed_expired_pairing(&db_path);
        let async_db = Arc::new(
            AsyncDaemonDb::connect(&db_path)
                .await
                .expect("open async pairing expiry database"),
        );

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let handle = spawn_remote_pairing_expiry_loop(async_db, shutdown_rx);
        wait_for_expiration(&db_path).await;
        shutdown_tx.send(true).expect("signal expiry loop shutdown");
        tokio::time::timeout(Duration::from_secs(1), handle)
            .await
            .expect("expiry loop shutdown timeout")
            .expect("join expiry loop");

        let events = DaemonDb::open(&db_path)
            .expect("reopen pairing expiry database")
            .load_remote_audit_events(20)
            .expect("load pairing expiry audits");
        let expiration_events = events
            .iter()
            .filter(|event| event.route_or_method == "remote.pair.expire")
            .collect::<Vec<_>>();
        assert_eq!(expiration_events.len(), 1);
        assert_eq!(
            expiration_events[0].event_id,
            "remote-pair-expire-pairing-background-expired"
        );
    }

    #[tokio::test]
    async fn remote_pairing_expiration_sweep_is_idempotent() {
        let temp = tempdir().expect("create pairing expiry sweep tempdir");
        let db_path = temp.path().join("harness.db");
        seed_expired_pairing(&db_path);
        let db = AsyncDaemonDb::connect(&db_path)
            .await
            .expect("open async pairing expiry sweep database");

        assert_eq!(
            db.record_expired_remote_pairings("2026-07-14T12:00:00Z")
                .await
                .expect("record first pairing expiration sweep"),
            1
        );
        assert_eq!(
            db.record_expired_remote_pairings("2026-07-14T12:00:30Z")
                .await
                .expect("record repeated pairing expiration sweep"),
            0
        );
    }

    #[tokio::test]
    async fn remote_pairing_expiry_loop_honors_presignaled_shutdown() {
        let temp = tempdir().expect("create presignaled shutdown tempdir");
        let db_path = temp.path().join("harness.db");
        seed_expired_pairing(&db_path);
        let async_db = Arc::new(
            AsyncDaemonDb::connect(&db_path)
                .await
                .expect("open presignaled shutdown database"),
        );
        let (_shutdown_tx, shutdown_rx) = watch::channel(true);

        let handle = spawn_remote_pairing_expiry_loop(async_db, shutdown_rx);

        tokio::time::timeout(Duration::from_millis(100), handle)
            .await
            .expect("presignaled expiry loop shutdown timeout")
            .expect("join presignaled expiry loop");
    }

    async fn wait_for_expiration(db_path: &std::path::Path) {
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let recorded = DaemonDb::open(db_path)
                    .expect("open pairing expiry poll database")
                    .load_remote_audit_events(20)
                    .expect("load pairing expiry poll audits")
                    .iter()
                    .any(|event| event.route_or_method == "remote.pair.expire");
                if recorded {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("pairing expiration audit timeout");
    }

    fn seed_expired_pairing(db_path: &std::path::Path) {
        let db = DaemonDb::open(db_path).expect("open pairing expiry database");
        let code = RemotePairingCode::from_value_for_tests("background-expired-secret");
        let record = RemotePairingRecord::new_for_tests(
            "pairing-background-expired",
            RemoteRole::Viewer,
            &[RemoteAccessScope::Read],
            code.expose(),
            "2020-01-01T00:00:00Z",
            "2020-01-01T00:10:00Z",
        )
        .expect("build expired pairing");
        db.create_remote_pairing_code(&record, "audit-create-background-expired")
            .expect("seed expired pairing");
    }
}
