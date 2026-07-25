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

impl Store {
    /// Start a sign-in, returning the `state` value to send to GitHub.
    ///
    /// # Errors
    /// Returns [`PanelError::Config`] when the system random source fails and
    /// [`PanelError::Storage`] when the write fails.
    pub async fn create_oauth_state(
        &self,
        ttl: Duration,
        now: DateTime<Utc>,
    ) -> Result<OpaqueToken, PanelError> {
        let state = OpaqueToken::generate()?;
        sqlx::query(
            "INSERT INTO oauth_states (state_hash, created_at, expires_at) VALUES (?1, ?2, ?3)",
        )
        .bind(state.hash())
        .bind(to_unix_seconds(now))
        .bind(to_unix_seconds(now + ttl))
        .execute(self.pool())
        .await?;
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
    use chrono::{Duration, TimeZone, Utc};

    use crate::store::Store;
    use crate::store::token::hash_token;

    fn at(minute: u32) -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 25, 10, minute, 0)
            .single()
            .expect("a valid timestamp")
    }

    #[tokio::test]
    async fn a_state_the_panel_issued_is_accepted() {
        let store = Store::open_in_memory().await.expect("store");

        let state = store
            .create_oauth_state(Duration::minutes(10), at(0))
            .await
            .expect("state");

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
        let state = store
            .create_oauth_state(Duration::minutes(10), at(0))
            .await
            .expect("state");

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
        let state = store
            .create_oauth_state(Duration::minutes(10), at(0))
            .await
            .expect("state");

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

        let state = store
            .create_oauth_state(Duration::minutes(10), at(0))
            .await
            .expect("state");

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
        let first = store
            .create_oauth_state(Duration::minutes(10), at(0))
            .await
            .expect("first");
        let second = store
            .create_oauth_state(Duration::minutes(10), at(0))
            .await
            .expect("second");

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
}
