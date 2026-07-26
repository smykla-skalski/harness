//! What the panel remembers about the links it minted.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::Row;

use super::{Store, from_unix_seconds, to_unix_seconds};

/// A link the panel issued, without the link.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PairLinkRecord {
    /// The daemon's own identifier for the pairing, so an operator can match
    /// this row against what the daemon holds. Between claiming a slot and
    /// learning what the daemon called the pairing, a row carries a
    /// `reservation:` id instead.
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

    /// Take one of this account's link slots, before anything has been minted.
    ///
    /// Returns `false` when the account already holds `max_live` unexpired
    /// links. The count and the row that changes it are one statement, which
    /// `SQLite` runs under its write lock: reading the count and then inserting
    /// would let two requests both see the last slot free and both take it,
    /// and the cap is what bounds how many live one-time codes an approved
    /// account can accumulate.
    ///
    /// The reservation carries the lifetime the panel is about to ask for, so
    /// one abandoned by a crash between here and the daemon stops counting on
    /// its own rather than costing the account a slot for good.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the write fails.
    pub async fn reserve_pair_link(
        &self,
        reservation: &PairLinkRecord,
        max_live: i64,
        now: DateTime<Utc>,
    ) -> Result<bool, sqlx::Error> {
        let taken = sqlx::query(
            "INSERT INTO pair_links (id, account_id, role, created_at, expires_at) \
             SELECT ?1, ?2, ?3, ?4, ?5 \
             WHERE (SELECT COUNT(*) FROM pair_links \
                    WHERE account_id = ?2 AND expires_at > ?6) < ?7",
        )
        .bind(&reservation.id)
        .bind(&reservation.account_id)
        .bind(&reservation.role)
        .bind(to_unix_seconds(reservation.created_at))
        .bind(to_unix_seconds(reservation.expires_at))
        .bind(to_unix_seconds(now))
        .bind(max_live)
        .execute(self.pool())
        .await?
        .rows_affected();

        Ok(taken == 1)
    }

    /// Replace a reservation with what the daemon actually issued.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the write fails, and
    /// [`sqlx::Error::RowNotFound`] when the reservation is gone. Answering
    /// `Ok` to that would report a link as recorded while the row that should
    /// carry it does not exist, and the record is the only thing an operator
    /// has to find a live link by.
    pub async fn finalize_pair_link(
        &self,
        reservation_id: &str,
        record: &PairLinkRecord,
    ) -> Result<(), sqlx::Error> {
        let updated = sqlx::query(
            "UPDATE pair_links SET id = ?1, role = ?2, created_at = ?3, expires_at = ?4 \
             WHERE id = ?5",
        )
        .bind(&record.id)
        .bind(&record.role)
        .bind(to_unix_seconds(record.created_at))
        .bind(to_unix_seconds(record.expires_at))
        .bind(reservation_id)
        .execute(self.pool())
        .await?
        .rows_affected();

        if updated == 0 {
            return Err(sqlx::Error::RowNotFound);
        }
        Ok(())
    }

    /// Give back a slot the daemon never minted against.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the write fails.
    pub async fn release_pair_link(&self, reservation_id: &str) -> Result<(), sqlx::Error> {
        sqlx::query("DELETE FROM pair_links WHERE id = ?1")
            .bind(reservation_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    /// How many of this account's links have not yet expired.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the query fails.
    pub async fn live_pair_link_count(
        &self,
        account_id: &str,
        now: DateTime<Utc>,
    ) -> Result<i64, sqlx::Error> {
        let row = sqlx::query(
            "SELECT COUNT(*) AS live FROM pair_links WHERE account_id = ?1 AND expires_at > ?2",
        )
        .bind(account_id)
        .bind(to_unix_seconds(now))
        .fetch_one(self.pool())
        .await?;
        Ok(row.get("live"))
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

    /// The point of reserving is that the slot is gone the moment it is taken,
    /// before the daemon has said anything, so a second request racing the
    /// first cannot see it free.
    #[tokio::test]
    async fn a_reservation_occupies_its_slot_before_anything_is_minted() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;

        assert!(
            store
                .reserve_pair_link(&record("reservation:1", &ada.id, 11), 1, at(11))
                .await
                .expect("first reservation")
        );
        assert_eq!(
            store
                .live_pair_link_count(&ada.id, at(11))
                .await
                .expect("count"),
            1
        );
        assert!(
            !store
                .reserve_pair_link(&record("reservation:2", &ada.id, 11), 1, at(11))
                .await
                .expect("second reservation"),
            "the cap must refuse the second while the first is still unminted"
        );
    }

    /// A daemon that refused must not cost the account a link it never got.
    #[tokio::test]
    async fn releasing_a_reservation_gives_the_slot_back() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;
        store
            .reserve_pair_link(&record("reservation:1", &ada.id, 11), 1, at(11))
            .await
            .expect("reservation");

        store
            .release_pair_link("reservation:1")
            .await
            .expect("release");

        assert!(
            store
                .reserve_pair_link(&record("reservation:2", &ada.id, 11), 1, at(11))
                .await
                .expect("second reservation")
        );
    }

    /// The row an operator reconciles against the daemon has to end up carrying
    /// the daemon's own identifier, not the placeholder it started as.
    #[tokio::test]
    async fn finalizing_replaces_the_reservation_with_the_daemon_pairing() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;
        store
            .reserve_pair_link(&record("reservation:1", &ada.id, 11), 5, at(11))
            .await
            .expect("reservation");

        let minted = record("pair-1", &ada.id, 12);
        store
            .finalize_pair_link("reservation:1", &minted)
            .await
            .expect("finalize");

        assert_eq!(
            store.pair_links_for_account(&ada.id).await.expect("list"),
            vec![minted],
            "one row, carrying what the daemon issued"
        );
    }

    /// Finalizing writes over a row that must already be there. If it is not —
    /// the account was removed and took its rows with it, or another process
    /// holds the same database — then answering `Ok` would log the link as
    /// recorded while nothing holds it, and the record is the only way an
    /// operator finds a live link to revoke.
    #[tokio::test]
    async fn finalizing_a_reservation_that_is_gone_is_an_error() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;

        let error = store
            .finalize_pair_link("reservation:vanished", &record("pair-1", &ada.id, 12))
            .await
            .expect_err("a missing reservation must not read as recorded");

        assert!(matches!(error, sqlx::Error::RowNotFound), "{error}");
        assert!(
            store
                .pair_links_for_account(&ada.id)
                .await
                .expect("list")
                .is_empty()
        );
    }

    /// An expired reservation is one the panel abandoned, and holding a slot
    /// for it for good would cost the account a link over a crash.
    #[tokio::test]
    async fn an_abandoned_reservation_stops_counting_once_it_lapses() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;
        store
            .reserve_pair_link(&record("reservation:1", &ada.id, 11), 1, at(11))
            .await
            .expect("reservation");

        // `record` expires a reservation an hour after it was created.
        assert!(
            store
                .reserve_pair_link(&record("reservation:2", &ada.id, 13), 1, at(13))
                .await
                .expect("later reservation")
        );
    }

    /// A revoke cannot reach a link already minted, so the only defence
    /// against one approved account holding a pile of live credentials is a cap
    /// on how many it can have at once.
    #[tokio::test]
    async fn only_unexpired_links_count_towards_the_cap() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;

        store
            .record_pair_link(&record("pair-1", &ada.id, 11))
            .await
            .expect("first");
        store
            .record_pair_link(&record("pair-2", &ada.id, 20))
            .await
            .expect("second");

        // `record` expires a link an hour after it was created.
        assert_eq!(
            store
                .live_pair_link_count(&ada.id, at(13))
                .await
                .expect("count"),
            1,
            "the first has lapsed"
        );
        assert_eq!(
            store
                .live_pair_link_count(&ada.id, at(11))
                .await
                .expect("count"),
            2
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
