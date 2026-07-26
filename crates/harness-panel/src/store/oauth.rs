//! Sign-ins that have started and not yet come back.
//!
//! The `state` value GitHub echoes to the callback is only worth anything if
//! the panel can prove it issued it, so it is stored here and deleted on use.
//! That single delete is what makes a replayed callback URL fail, and what
//! stops a third party from feeding someone else's browser an authorization
//! code the panel would otherwise happily exchange.

use chrono::{DateTime, Duration, Utc};

use super::token::{OpaqueToken, hash_token};
use super::{Store, to_unix_seconds};
use crate::error::PanelError;

/// A global bound on unfinished OAuth handshakes.
///
/// The start route is public, so a browser cookie cannot be the resource
/// limit: a caller can discard it. This cap bounds `SQLite` work across every
/// caller and every panel process sharing the database.
pub const MAX_ACTIVE_OAUTH_STATES: i64 = 256;

impl Store {
    /// Start a sign-in, returning the `state` value to send to GitHub.
    ///
    /// Once the bounded active-state window is full, its oldest value is
    /// replaced. A public caller therefore cannot permanently exhaust sign-in
    /// capacity by filling the window once. Any pre-existing overflow is
    /// discarded oldest-first in the same transaction.
    ///
    /// # Errors
    /// Returns [`PanelError::Config`] when the system random source fails and
    /// [`PanelError::Storage`] when the write fails.
    pub async fn create_oauth_state(
        &self,
        ttl: Duration,
        now: DateTime<Utc>,
    ) -> Result<OpaqueToken, PanelError> {
        self.create_oauth_state_with_limit(ttl, now, MAX_ACTIVE_OAUTH_STATES)
            .await
    }

    async fn create_oauth_state_with_limit(
        &self,
        ttl: Duration,
        now: DateTime<Utc>,
        limit: i64,
    ) -> Result<OpaqueToken, PanelError> {
        let state = OpaqueToken::generate()?;
        let now = to_unix_seconds(now);
        let mut transaction = self.pool().begin_with("BEGIN IMMEDIATE").await?;

        sqlx::query("DELETE FROM oauth_states WHERE expires_at <= ?1")
            .bind(now)
            .execute(transaction.as_mut())
            .await?;
        // Creation times have one-second precision; `rowid` preserves insertion
        // order when several active states share the oldest timestamp.
        sqlx::query(
            "DELETE FROM oauth_states WHERE state_hash IN (\
             SELECT state_hash FROM oauth_states \
             ORDER BY created_at ASC, rowid ASC \
             LIMIT max(0, (SELECT COUNT(*) FROM oauth_states) - ?1 + 1))",
        )
        .bind(limit)
        .execute(transaction.as_mut())
        .await?;
        sqlx::query(
            "INSERT INTO oauth_states (state_hash, created_at, expires_at) VALUES (?1, ?2, ?3)",
        )
        .bind(state.hash())
        .bind(now)
        .bind(now.saturating_add(ttl.num_seconds()))
        .execute(transaction.as_mut())
        .await?;
        transaction.commit().await?;
        Ok(state)
    }

    /// Accept a `state` value exactly once.
    ///
    /// Returns `true` when the panel issued this value and it has not expired
    /// or been used. The check and the delete are one statement, so two
    /// callbacks racing on the same value cannot both be accepted.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the delete fails.
    pub async fn consume_oauth_state(
        &self,
        state: &str,
        now: DateTime<Utc>,
    ) -> Result<bool, sqlx::Error> {
        let removed =
            sqlx::query("DELETE FROM oauth_states WHERE state_hash = ?1 AND expires_at > ?2")
                .bind(hash_token(state))
                .bind(to_unix_seconds(now))
                .execute(self.pool())
                .await?
                .rows_affected();
        Ok(removed > 0)
    }
}

#[cfg(test)]
mod tests {
    use chrono::{DateTime, Duration, TimeZone, Utc};

    use crate::store::Store;
    use crate::store::token::{OpaqueToken, hash_token};

    fn at(minute: u32) -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 25, 10, minute, 0)
            .single()
            .expect("a valid timestamp")
    }

    async fn issue(store: &Store, now: DateTime<Utc>) -> OpaqueToken {
        store
            .create_oauth_state(Duration::minutes(10), now)
            .await
            .expect("state write")
    }

    #[tokio::test]
    async fn a_state_the_panel_issued_is_accepted() {
        let store = Store::open_in_memory().await.expect("store");

        let state = issue(&store, at(0)).await;

        assert!(
            store
                .consume_oauth_state(state.expose(), at(1))
                .await
                .expect("consume")
        );
    }

    /// Accepting the same callback twice would let anyone who saw the URL —
    /// in a referrer header, a proxy log, or browser history — replay it.
    #[tokio::test]
    async fn a_state_is_accepted_only_once() {
        let store = Store::open_in_memory().await.expect("store");
        let state = issue(&store, at(0)).await;

        assert!(
            store
                .consume_oauth_state(state.expose(), at(1))
                .await
                .expect("first")
        );
        assert!(
            !store
                .consume_oauth_state(state.expose(), at(1))
                .await
                .expect("second")
        );
    }

    /// A value the panel never issued is what a forged callback carries.
    #[tokio::test]
    async fn a_state_the_panel_never_issued_is_refused() {
        let store = Store::open_in_memory().await.expect("store");

        assert!(
            !store
                .consume_oauth_state("forged", at(1))
                .await
                .expect("consume")
        );
    }

    #[tokio::test]
    async fn an_expired_state_is_refused_and_leaves_nothing_usable() {
        let store = Store::open_in_memory().await.expect("store");
        let state = issue(&store, at(0)).await;

        assert!(
            !store
                .consume_oauth_state(state.expose(), at(11))
                .await
                .expect("consume")
        );
        assert_eq!(store.prune_expired(at(11)).await.expect("prune"), 1);
    }

    #[tokio::test]
    async fn only_the_hash_of_a_state_is_stored() {
        let store = Store::open_in_memory().await.expect("store");

        let state = issue(&store, at(0)).await;

        let stored: Vec<(String,)> = sqlx::query_as("SELECT state_hash FROM oauth_states")
            .fetch_all(store.pool())
            .await
            .expect("reading states");

        assert_eq!(stored[0].0, hash_token(state.expose()));
        assert_ne!(stored[0].0, state.expose());
    }

    /// Two tabs starting a sign-in at once must both be able to finish.
    #[tokio::test]
    async fn concurrent_sign_ins_do_not_invalidate_each_other() {
        let store = Store::open_in_memory().await.expect("store");
        let first = issue(&store, at(0)).await;
        let second = issue(&store, at(0)).await;

        assert!(
            store
                .consume_oauth_state(first.expose(), at(1))
                .await
                .expect("first")
        );
        assert!(
            store
                .consume_oauth_state(second.expose(), at(1))
                .await
                .expect("second")
        );
    }

    #[tokio::test]
    async fn concurrent_inserts_keep_the_outstanding_state_window_bounded() {
        let directory = tempfile::tempdir().expect("temp dir");
        let store = Store::open(directory.path()).await.expect("store");

        let (first, second) = tokio::join!(
            store.create_oauth_state_with_limit(Duration::minutes(10), at(0), 1),
            store.create_oauth_state_with_limit(Duration::minutes(10), at(0), 1)
        );
        let first = first.expect("first");
        let second = second.expect("second");
        let stored: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM oauth_states")
            .fetch_one(store.pool())
            .await
            .expect("count");

        assert_eq!(stored, 1);
        let first_active = store
            .consume_oauth_state(first.expose(), at(1))
            .await
            .expect("first state");
        let second_active = store
            .consume_oauth_state(second.expose(), at(1))
            .await
            .expect("second state");
        assert_ne!(first_active, second_active);
    }

    #[tokio::test]
    async fn the_oldest_active_state_is_evicted_before_issuing() {
        let store = Store::open_in_memory().await.expect("store");
        let first = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(0), 2)
            .await
            .expect("first");
        let second = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(1), 2)
            .await
            .expect("second");
        let third = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(2), 2)
            .await
            .expect("third");

        assert!(
            !store
                .consume_oauth_state(first.expose(), at(3))
                .await
                .expect("oldest")
        );
        assert!(
            store
                .consume_oauth_state(second.expose(), at(3))
                .await
                .expect("second")
        );
        assert!(
            store
                .consume_oauth_state(third.expose(), at(3))
                .await
                .expect("third")
        );
    }

    #[tokio::test]
    async fn expired_capacity_is_pruned_before_eviction() {
        let store = Store::open_in_memory().await.expect("store");
        let expired = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(0), 1)
            .await
            .expect("first");
        let issued = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(10), 1)
            .await
            .expect("reclaimed");

        assert!(
            !store
                .consume_oauth_state(expired.expose(), at(10))
                .await
                .expect("expired")
        );
        assert!(
            store
                .consume_oauth_state(issued.expose(), at(10))
                .await
                .expect("issued")
        );
    }

    #[tokio::test]
    async fn preexisting_overflow_is_repaired_before_issuing() {
        let store = Store::open_in_memory().await.expect("store");
        for index in 0..3 {
            sqlx::query(
                "INSERT INTO oauth_states (state_hash, created_at, expires_at) \
                 VALUES (?1, ?2, ?3)",
            )
            .bind(format!("occupied-{index}"))
            .bind(index)
            .bind(i64::MAX)
            .execute(store.pool())
            .await
            .expect("seed overflow");
        }

        let issued = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(3), 2)
            .await
            .expect("issued");
        let stored: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM oauth_states")
            .fetch_one(store.pool())
            .await
            .expect("count");
        let newest_existing: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM oauth_states WHERE state_hash = 'occupied-2'")
                .fetch_one(store.pool())
                .await
                .expect("newest existing");

        assert_eq!(stored, 2);
        assert_eq!(newest_existing, 1);
        assert!(
            store
                .consume_oauth_state(issued.expose(), at(4))
                .await
                .expect("new state")
        );
    }
}
