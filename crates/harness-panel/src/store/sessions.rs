//! Server-side sessions.
//!
//! The cookie carries an opaque token and nothing else. Everything the panel
//! decides from it — which account, still valid or not — is read back out of
//! this table, so signing someone out or expiring them takes effect at once
//! rather than whenever the browser next drops the cookie.

use chrono::{DateTime, Duration, Utc};

use super::accounts::{Account, AccountIdentity, upsert_account_with};
use super::token::{OpaqueToken, hash_token};
use super::{Store, from_unix_seconds, to_unix_seconds};
use crate::error::PanelError;
use sqlx::Row;

/// A live session and the account behind it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionRecord {
    pub account: Account,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

impl Store {
    /// Record a successful identity, bind the owner when eligible, and issue
    /// the session returned to the browser.
    ///
    /// The account upsert, owner claim, and session insert share one
    /// transaction. A failed session insert therefore cannot leave behind an
    /// account or claim from a callback that never completed, while `INSERT OR
    /// IGNORE` keeps concurrent owner callbacks first-writer-wins.
    ///
    /// # Errors
    /// Returns [`PanelError::Config`] when the system random source fails and
    /// [`PanelError::Storage`] when a database operation fails.
    pub async fn complete_sign_in(
        &self,
        identity: &AccountIdentity,
        claim_owner: bool,
        ttl: Duration,
        now: DateTime<Utc>,
    ) -> Result<(Account, OpaqueToken), PanelError> {
        let token = OpaqueToken::generate()?;
        let timestamp = to_unix_seconds(now);
        let mut transaction = self.pool().begin_with("BEGIN IMMEDIATE").await?;
        let account = upsert_account_with(transaction.as_mut(), identity, now).await?;

        if claim_owner {
            sqlx::query(
                "INSERT OR IGNORE INTO owner_binding \
                 (id, provider, subject_id, login, bound_at) VALUES (1, ?1, ?2, ?3, ?4)",
            )
            .bind(&account.provider)
            .bind(&account.subject_id)
            .bind(&account.login)
            .bind(timestamp)
            .execute(transaction.as_mut())
            .await?;
        }
        sqlx::query(
            "INSERT INTO sessions (token_hash, account_id, created_at, expires_at) \
             VALUES (?1, ?2, ?3, ?4)",
        )
        .bind(token.hash())
        .bind(&account.id)
        .bind(timestamp)
        .bind(to_unix_seconds(now + ttl))
        .execute(transaction.as_mut())
        .await?;
        transaction.commit().await?;

        Ok((account, token))
    }

    /// Issue a session for `account_id`, returning the token to hand out once.
    ///
    /// # Errors
    /// Returns [`PanelError::Config`] when the system random source fails and
    /// [`PanelError::Storage`] when the write fails.
    pub async fn create_session(
        &self,
        account_id: &str,
        ttl: Duration,
        now: DateTime<Utc>,
    ) -> Result<OpaqueToken, PanelError> {
        let token = OpaqueToken::generate()?;
        sqlx::query(
            "INSERT INTO sessions (token_hash, account_id, created_at, expires_at) \
             VALUES (?1, ?2, ?3, ?4)",
        )
        .bind(token.hash())
        .bind(account_id)
        .bind(to_unix_seconds(now))
        .bind(to_unix_seconds(now + ttl))
        .execute(self.pool())
        .await?;
        Ok(token)
    }

    /// Resolve a presented token to its account, or `None` when the session is
    /// unknown or has expired.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the query fails.
    pub async fn session_for_token(
        &self,
        token: &str,
        now: DateTime<Utc>,
    ) -> Result<Option<SessionRecord>, sqlx::Error> {
        // Expiry is filtered here rather than trusted to a background sweep, so
        // an expired row is unusable the moment it expires even if nothing has
        // pruned it yet.
        //
        // The account is fetched separately rather than joined in. A join has to
        // restate every account column, and a column added later that this
        // projection missed would leave the shared row reader looking for a
        // field that is not there, failing at runtime on a query nobody edited.
        // One extra primary-key lookup is a fair price for that being
        // impossible.
        let Some(row) = sqlx::query(
            "SELECT account_id, created_at, expires_at FROM sessions \
             WHERE token_hash = ?1 AND expires_at > ?2",
        )
        .bind(hash_token(token))
        .bind(to_unix_seconds(now))
        .fetch_optional(self.pool())
        .await?
        else {
            return Ok(None);
        };

        let account_id: String = row.get("account_id");
        let Some(account) = self.account_by_id(&account_id).await? else {
            return Ok(None);
        };

        Ok(Some(SessionRecord {
            account,
            created_at: from_unix_seconds(row.get("created_at")),
            expires_at: from_unix_seconds(row.get("expires_at")),
        }))
    }

    /// Delete a session, whether or not it had already expired.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the delete fails.
    pub async fn delete_session(&self, token: &str) -> Result<bool, sqlx::Error> {
        let removed = sqlx::query("DELETE FROM sessions WHERE token_hash = ?1")
            .bind(hash_token(token))
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
    use crate::store::accounts::AccountIdentity;
    use crate::store::token::hash_token;

    fn ada() -> AccountIdentity {
        AccountIdentity {
            provider: "github:https://api.github.com".to_owned(),
            subject_id: "4242".to_owned(),
            login: "ada".to_owned(),
            display_name: "Ada Lovelace".to_owned(),
            avatar_url: None,
        }
    }

    fn at(hour: u32) -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 25, hour, 0, 0)
            .single()
            .expect("a valid timestamp")
    }

    async fn store_with_ada() -> (Store, String) {
        let store = Store::open_in_memory().await.expect("store");
        let account = store.upsert_account(&ada(), at(10)).await.expect("account");
        (store, account.id)
    }

    #[tokio::test]
    async fn a_session_resolves_to_its_account() {
        let (store, account_id) = store_with_ada().await;

        let token = store
            .create_session(&account_id, Duration::hours(12), at(10))
            .await
            .expect("session");
        let session = store
            .session_for_token(token.expose(), at(11))
            .await
            .expect("lookup")
            .expect("the session is live");

        assert_eq!(session.account.id, account_id);
        assert_eq!(session.account.login, "ada");
        assert_eq!(session.expires_at, at(22));
    }

    #[tokio::test]
    async fn completing_sign_in_claims_the_owner_before_the_session_is_used() {
        let store = Store::open_in_memory().await.expect("store");

        let (account, token) = store
            .complete_sign_in(&ada(), true, Duration::hours(12), at(10))
            .await
            .expect("complete sign-in");
        let binding = store
            .owner_binding()
            .await
            .expect("binding")
            .expect("the callback claimed the panel");

        assert!(binding.matches(&account));
        assert!(
            store
                .session_for_token(token.expose(), at(11))
                .await
                .expect("session")
                .is_some()
        );
    }

    #[tokio::test]
    async fn a_failed_session_insert_rolls_back_the_account_and_owner_claim() {
        let store = Store::open_in_memory().await.expect("store");
        sqlx::query(
            "CREATE TRIGGER reject_session_insert BEFORE INSERT ON sessions \
             BEGIN SELECT RAISE(ABORT, 'session insert rejected'); END",
        )
        .execute(store.pool())
        .await
        .expect("install failure trigger");

        assert!(
            store
                .complete_sign_in(&ada(), true, Duration::hours(12), at(10))
                .await
                .is_err()
        );
        assert!(store.list_accounts().await.expect("accounts").is_empty());
        assert!(store.owner_binding().await.expect("binding").is_none());
    }

    #[tokio::test]
    async fn a_later_owner_candidate_cannot_displace_the_callback_that_won() {
        let store = Store::open_in_memory().await.expect("store");
        let stranger = AccountIdentity {
            subject_id: "7777".to_owned(),
            ..ada()
        };

        let (owner, _) = store
            .complete_sign_in(&ada(), true, Duration::hours(12), at(10))
            .await
            .expect("owner sign-in");
        let (later, _) = store
            .complete_sign_in(&stranger, true, Duration::hours(12), at(11))
            .await
            .expect("later sign-in");
        let binding = store
            .owner_binding()
            .await
            .expect("binding")
            .expect("claimed");

        assert!(binding.matches(&owner));
        assert!(!binding.matches(&later));
    }

    /// The token is what the browser holds; the table holds only its hash, so a
    /// stolen copy of the database is not a set of working sessions.
    #[tokio::test]
    async fn only_the_hash_of_a_token_is_stored() {
        let (store, account_id) = store_with_ada().await;

        let token = store
            .create_session(&account_id, Duration::hours(12), at(10))
            .await
            .expect("session");

        let stored: Vec<(String,)> = sqlx::query_as("SELECT token_hash FROM sessions")
            .fetch_all(store.pool())
            .await
            .expect("reading sessions");

        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].0, hash_token(token.expose()));
        assert_ne!(stored[0].0, token.expose());
    }

    /// An expired row stays readable until something prunes it, so the lookup
    /// itself has to refuse it rather than rely on the sweep having run.
    #[tokio::test]
    async fn an_expired_session_stops_resolving_before_it_is_pruned() {
        let (store, account_id) = store_with_ada().await;
        let token = store
            .create_session(&account_id, Duration::hours(1), at(10))
            .await
            .expect("session");

        assert!(
            store
                .session_for_token(token.expose(), at(12))
                .await
                .expect("lookup")
                .is_none()
        );

        let removed = store.prune_expired(at(12)).await.expect("prune");
        assert_eq!(removed, 1);
    }

    /// Expiry is exclusive at the boundary: a session whose deadline is exactly
    /// now has run out.
    #[tokio::test]
    async fn a_session_is_dead_at_its_expiry_instant() {
        let (store, account_id) = store_with_ada().await;
        let token = store
            .create_session(&account_id, Duration::hours(1), at(10))
            .await
            .expect("session");

        assert!(
            store
                .session_for_token(token.expose(), at(11))
                .await
                .expect("lookup")
                .is_none()
        );
    }

    #[tokio::test]
    async fn an_unknown_token_resolves_to_nothing() {
        let (store, _) = store_with_ada().await;

        assert!(
            store
                .session_for_token("not-a-session", at(11))
                .await
                .expect("lookup")
                .is_none()
        );
    }

    /// Signing out has to take effect on the server; a browser that keeps the
    /// cookie must not keep the session.
    #[tokio::test]
    async fn signing_out_invalidates_the_token_immediately() {
        let (store, account_id) = store_with_ada().await;
        let token = store
            .create_session(&account_id, Duration::hours(12), at(10))
            .await
            .expect("session");

        assert!(store.delete_session(token.expose()).await.expect("delete"));
        assert!(
            store
                .session_for_token(token.expose(), at(11))
                .await
                .expect("lookup")
                .is_none()
        );
        assert!(!store.delete_session(token.expose()).await.expect("delete"));
    }

    /// Signing in on a second device must not end the first device's session.
    #[tokio::test]
    async fn sessions_are_independent_of_each_other() {
        let (store, account_id) = store_with_ada().await;
        let first = store
            .create_session(&account_id, Duration::hours(12), at(10))
            .await
            .expect("first session");
        let second = store
            .create_session(&account_id, Duration::hours(12), at(10))
            .await
            .expect("second session");

        store.delete_session(first.expose()).await.expect("delete");

        assert!(
            store
                .session_for_token(second.expose(), at(11))
                .await
                .expect("lookup")
                .is_some()
        );
    }
}
