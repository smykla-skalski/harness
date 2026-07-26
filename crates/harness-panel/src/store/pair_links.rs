//! What the panel remembers about the links it minted.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::Row;

use super::{Store, from_unix_seconds, to_unix_seconds};
use crate::daemon_client::RESERVATION_PREFIX;

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

    /// Which account each recorded link was minted for.
    ///
    /// The daemon knows what it issued but not who the panel issued it for, so
    /// this is the panel's half of the join. Reservations are left out: they
    /// stand for links the daemon never confirmed, carry an id no pairing will
    /// ever have, and would only ever match nothing.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the query fails.
    pub async fn pair_link_accounts(&self) -> Result<HashMap<String, String>, sqlx::Error> {
        let rows = sqlx::query("SELECT id, account_id FROM pair_links WHERE id NOT LIKE ?1")
            .bind(format!("{RESERVATION_PREFIX}%"))
            .fetch_all(self.pool())
            .await?;

        Ok(rows
            .iter()
            .map(|row| (row.get("id"), row.get("account_id")))
            .collect())
    }

    /// Which account one link was minted for.
    ///
    /// Asked about a single pairing rather than by reading the whole map, which
    /// is what a revoke needs and what it would otherwise have to scan.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the query fails.
    pub async fn pair_link_account(
        &self,
        pairing_id: &str,
    ) -> Result<Option<String>, sqlx::Error> {
        // A reservation id is refused rather than looked up. One can only be
        // supplied by a caller that guessed the panel's internal spelling, and
        // a hit would let it act on a slot rather than on a pairing.
        if pairing_id.starts_with(RESERVATION_PREFIX) {
            return Ok(None);
        }
        let row = sqlx::query("SELECT account_id FROM pair_links WHERE id = ?1")
            .bind(pairing_id)
            .fetch_optional(self.pool())
            .await?;

        Ok(row.as_ref().map(|row| row.get("account_id")))
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
mod tests;
