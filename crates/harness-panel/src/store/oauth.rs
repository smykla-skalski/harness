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
    /// Start a sign-in, returning the `state` value to send to GitHub, or
    /// `None` while the global outstanding-state capacity is full.
    ///
    /// # Errors
    /// Returns [`PanelError::Config`] when the system random source fails and
    /// [`PanelError::Storage`] when the write fails.
    pub async fn create_oauth_state(
        &self,
        ttl: Duration,
        now: DateTime<Utc>,
    ) -> Result<Option<OpaqueToken>, PanelError> {
        self.create_oauth_state_with_limit(ttl, now, MAX_ACTIVE_OAUTH_STATES)
            .await
    }

    async fn create_oauth_state_with_limit(
        &self,
        ttl: Duration,
        now: DateTime<Utc>,
        limit: i64,
    ) -> Result<Option<OpaqueToken>, PanelError> {
        let state = OpaqueToken::generate()?;
        let now = to_unix_seconds(now);
        let mut transaction = self.pool().begin_with("BEGIN IMMEDIATE").await?;

        sqlx::query("DELETE FROM oauth_states WHERE expires_at <= ?1")
            .bind(now)
            .execute(transaction.as_mut())
            .await?;
        let inserted = sqlx::query(
            "INSERT INTO oauth_states (state_hash, created_at, expires_at) \
             SELECT ?1, ?2, ?3 WHERE \
             (SELECT COUNT(*) FROM oauth_states) < ?4",
        )
        .bind(state.hash())
        .bind(now)
        .bind(now.saturating_add(ttl.num_seconds()))
        .bind(limit)
        .execute(transaction.as_mut())
        .await?
        .rows_affected()
            > 0;
        transaction.commit().await?;
        Ok(inserted.then_some(state))
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
            .expect("state capacity")
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
    async fn the_outstanding_state_cap_is_atomic_across_connections() {
        let directory = tempfile::tempdir().expect("temp dir");
        let store = Store::open(directory.path()).await.expect("store");

        let (first, second) = tokio::join!(
            store.create_oauth_state_with_limit(Duration::minutes(10), at(0), 1),
            store.create_oauth_state_with_limit(Duration::minutes(10), at(0), 1)
        );
        let issued = [first.expect("first"), second.expect("second")]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
        let stored: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM oauth_states")
            .fetch_one(store.pool())
            .await
            .expect("count");

        assert_eq!(issued.len(), 1);
        assert_eq!(stored, 1);
        assert!(
            store
                .consume_oauth_state(issued[0].expose(), at(1))
                .await
                .expect("issued state")
        );
    }

    #[tokio::test]
    async fn full_capacity_refuses_a_new_state_without_destroying_existing_states() {
        let store = Store::open_in_memory().await.expect("store");
        let first = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(0), 2)
            .await
            .expect("first")
            .expect("first capacity");
        let second = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(1), 2)
            .await
            .expect("second")
            .expect("second capacity");
        let refused = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(2), 2)
            .await
            .expect("full");

        assert!(refused.is_none());
        assert!(
            store
                .consume_oauth_state(first.expose(), at(3))
                .await
                .expect("first")
        );
        assert!(
            store
                .consume_oauth_state(second.expose(), at(3))
                .await
                .expect("second")
        );
    }

    #[tokio::test]
    async fn expired_capacity_is_pruned_before_issuing() {
        let store = Store::open_in_memory().await.expect("store");
        let expired = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(0), 1)
            .await
            .expect("first")
            .expect("first capacity");
        let issued = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(10), 1)
            .await
            .expect("reclaimed")
            .expect("reclaimed capacity");

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
    async fn preexisting_overflow_is_preserved_and_refuses_a_new_state() {
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

        let refused = store
            .create_oauth_state_with_limit(Duration::minutes(10), at(3), 2)
            .await
            .expect("full");
        let stored: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM oauth_states")
            .fetch_one(store.pool())
            .await
            .expect("count");
        let existing: Vec<String> =
            sqlx::query_scalar("SELECT state_hash FROM oauth_states ORDER BY created_at")
                .fetch_all(store.pool())
                .await
                .expect("existing states");

        assert!(refused.is_none());
        assert_eq!(stored, 3);
        assert_eq!(existing, ["occupied-0", "occupied-1", "occupied-2"]);
    }
}
