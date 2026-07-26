//! The credential the panel authenticates to the daemon with.

use chrono::{DateTime, Utc};
use sqlx::Row;

use super::{Store, to_unix_seconds};
use crate::daemon_client::DaemonCredential;

impl Store {
    /// The stored credential, or `None` before the panel has claimed one.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the query fails.
    pub async fn daemon_credential(&self) -> Result<Option<DaemonCredential>, sqlx::Error> {
        let row = sqlx::query("SELECT client_id, token, role FROM daemon_credential WHERE id = 1")
            .fetch_optional(self.pool())
            .await?;

        Ok(row.map(|row| DaemonCredential {
            client_id: row.get("client_id"),
            token: row.get("token"),
            role: row.get("role"),
        }))
    }

    /// Store the credential the panel just claimed, replacing any earlier one.
    ///
    /// Replacing rather than refusing: re-pairing is how an operator recovers
    /// from a credential the daemon has revoked, and the old one is useless by
    /// then anyway.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the write fails.
    pub async fn store_daemon_credential(
        &self,
        credential: &DaemonCredential,
        now: DateTime<Utc>,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "INSERT INTO daemon_credential (id, client_id, token, role, claimed_at) \
             VALUES (1, ?1, ?2, ?3, ?4) \
             ON CONFLICT (id) DO UPDATE SET \
               client_id = excluded.client_id, \
               token = excluded.token, \
               role = excluded.role, \
               claimed_at = excluded.claimed_at",
        )
        .bind(&credential.client_id)
        .bind(&credential.token)
        .bind(&credential.role)
        .bind(to_unix_seconds(now))
        .execute(self.pool())
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};

    use crate::daemon_client::DaemonCredential;
    use crate::store::Store;

    fn at(hour: u32) -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 25, hour, 0, 0)
            .single()
            .expect("a valid timestamp")
    }

    fn credential(client_id: &str) -> DaemonCredential {
        DaemonCredential {
            client_id: client_id.to_owned(),
            token: format!("token-for-{client_id}"),
            role: "pairing_broker".to_owned(),
        }
    }

    #[tokio::test]
    async fn a_panel_that_has_not_paired_has_no_credential() {
        let store = Store::open_in_memory().await.expect("store");

        assert!(store.daemon_credential().await.expect("lookup").is_none());
    }

    #[tokio::test]
    async fn a_claimed_credential_survives_a_restart() {
        let store = Store::open_in_memory().await.expect("store");
        let claimed = credential("panel-1");

        store
            .store_daemon_credential(&claimed, at(10))
            .await
            .expect("store");

        assert_eq!(
            store.daemon_credential().await.expect("lookup"),
            Some(claimed)
        );
    }

    /// Re-pairing is how an operator recovers from a revoked credential, so a
    /// second claim replaces the first rather than sitting beside it.
    #[tokio::test]
    async fn re_pairing_replaces_the_credential() {
        let store = Store::open_in_memory().await.expect("store");
        store
            .store_daemon_credential(&credential("panel-1"), at(10))
            .await
            .expect("first");

        store
            .store_daemon_credential(&credential("panel-2"), at(11))
            .await
            .expect("second");

        let stored = store
            .daemon_credential()
            .await
            .expect("lookup")
            .expect("a credential");
        assert_eq!(stored.client_id, "panel-2");

        let rows: Vec<(i64,)> = sqlx::query_as("SELECT COUNT(*) FROM daemon_credential")
            .fetch_all(store.pool())
            .await
            .expect("counting");
        assert_eq!(rows[0].0, 1, "the panel talks to one daemon");
    }
}
