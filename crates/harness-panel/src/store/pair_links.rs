//! What the panel remembers about the links it minted.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::Row;

use super::{Store, from_unix_seconds, to_unix_seconds};

/// A link the panel issued, without the link.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairLinkRecord {
    /// The daemon's own identifier for the pairing, so an operator can match
    /// this row against what the daemon holds.
    pub id: String,
    pub account_id: String,
    pub role: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

impl Store {
    /// Record that a link was minted.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the write fails.
    pub async fn record_pair_link(&self, record: &PairLinkRecord) -> Result<(), sqlx::Error> {
        sqlx::query(
            "INSERT INTO pair_links (id, account_id, role, created_at, expires_at) \
             VALUES (?1, ?2, ?3, ?4, ?5)",
        )
        .bind(&record.id)
        .bind(&record.account_id)
        .bind(&record.role)
        .bind(to_unix_seconds(record.created_at))
        .bind(to_unix_seconds(record.expires_at))
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// Links this account has been issued, most recent first.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the query fails.
    pub async fn pair_links_for_account(
        &self,
        account_id: &str,
    ) -> Result<Vec<PairLinkRecord>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT id, account_id, role, created_at, expires_at FROM pair_links \
             WHERE account_id = ?1 ORDER BY created_at DESC, rowid DESC",
        )
        .bind(account_id)
        .fetch_all(self.pool())
        .await?;

        Ok(rows
            .iter()
            .map(|row| PairLinkRecord {
                id: row.get("id"),
                account_id: row.get("account_id"),
                role: row.get("role"),
                created_at: from_unix_seconds(row.get("created_at")),
                expires_at: from_unix_seconds(row.get("expires_at")),
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};

    use super::PairLinkRecord;
    use crate::store::Store;
    use crate::store::accounts::{Account, AccountIdentity};

    fn at(hour: u32) -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 25, hour, 0, 0)
            .single()
            .expect("a valid timestamp")
    }

    async fn account(store: &Store, login: &str, subject_id: &str) -> Account {
        store
            .upsert_account(
                &AccountIdentity {
                    provider: "github".to_owned(),
                    subject_id: subject_id.to_owned(),
                    login: login.to_owned(),
                    display_name: login.to_owned(),
                    avatar_url: None,
                },
                at(10),
            )
            .await
            .expect("account")
    }

    fn record(id: &str, account_id: &str, created: u32) -> PairLinkRecord {
        PairLinkRecord {
            id: id.to_owned(),
            account_id: account_id.to_owned(),
            role: "operator".to_owned(),
            created_at: at(created),
            expires_at: at(created + 1),
        }
    }

    #[tokio::test]
    async fn a_recorded_link_reads_back() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;

        let issued = record("pair-1", &ada.id, 11);
        store.record_pair_link(&issued).await.expect("record");

        assert_eq!(
            store.pair_links_for_account(&ada.id).await.expect("list"),
            vec![issued]
        );
    }

    /// The link carries a one-time code, so the row must hold nothing that
    /// could be used to claim it. Only the daemon's identifier for the pairing
    /// is kept, and that is not a credential.
    #[tokio::test]
    async fn no_column_can_hold_the_link_itself() {
        let store = Store::open_in_memory().await.expect("store");

        let columns: Vec<(String,)> =
            sqlx::query_as("SELECT name FROM pragma_table_info('pair_links')")
                .fetch_all(store.pool())
                .await
                .expect("columns");
        let names: Vec<&str> = columns.iter().map(|(name,)| name.as_str()).collect();

        assert_eq!(
            names,
            vec!["id", "account_id", "role", "created_at", "expires_at"]
        );
    }

    #[tokio::test]
    async fn links_are_listed_newest_first_and_per_account() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;
        let grace = account(&store, "grace", "99").await;

        store
            .record_pair_link(&record("pair-1", &ada.id, 11))
            .await
            .expect("first");
        store
            .record_pair_link(&record("pair-2", &ada.id, 13))
            .await
            .expect("second");
        store
            .record_pair_link(&record("pair-3", &grace.id, 12))
            .await
            .expect("other account");

        let ada_links = store.pair_links_for_account(&ada.id).await.expect("list");

        assert_eq!(
            ada_links
                .iter()
                .map(|link| link.id.as_str())
                .collect::<Vec<_>>(),
            vec!["pair-2", "pair-1"]
        );
    }
}
