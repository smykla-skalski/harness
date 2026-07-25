//! Which external identity owns this panel.
//!
//! `--owner-login` names a GitHub login, and a login is not a person: it can be
//! renamed, freeing the old name for anyone to register. So the flag decides
//! only who the binding is taken from, once. From then on ownership is the
//! immutable `(provider, subject_id)` pair, the same key accounts use.

use chrono::{DateTime, Utc};
use sqlx::Row;

use super::accounts::Account;
use super::{Store, from_unix_seconds, to_unix_seconds};

/// The identity this panel is owned by.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnerBinding {
    pub provider: String,
    pub subject_id: String,
    /// The login as it read when the binding was taken. Kept so an operator can
    /// recognise the row; never used to decide ownership.
    pub login: String,
    pub bound_at: DateTime<Utc>,
}

impl OwnerBinding {
    /// Whether this binding names the same external identity as `account`.
    #[must_use]
    pub fn matches(&self, account: &Account) -> bool {
        self.provider == account.provider && self.subject_id == account.subject_id
    }
}

impl Store {
    /// The owner binding, or `None` while the panel is still unclaimed.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the query fails.
    pub async fn owner_binding(&self) -> Result<Option<OwnerBinding>, sqlx::Error> {
        let row = sqlx::query(
            "SELECT provider, subject_id, login, bound_at FROM owner_binding WHERE id = 1",
        )
        .fetch_optional(self.pool())
        .await?;

        Ok(row.map(|row| OwnerBinding {
            provider: row.get("provider"),
            subject_id: row.get("subject_id"),
            login: row.get("login"),
            bound_at: from_unix_seconds(row.get("bound_at")),
        }))
    }

    /// Claim the panel for `account`, unless it is already claimed.
    ///
    /// `INSERT OR IGNORE` rather than a read-then-write, so two sign-ins racing
    /// on an unclaimed panel settle on whichever reached the database first
    /// instead of the second silently overwriting the first.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the write fails.
    pub async fn bind_owner(
        &self,
        account: &Account,
        now: DateTime<Utc>,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            "INSERT OR IGNORE INTO owner_binding (id, provider, subject_id, login, bound_at) \
             VALUES (1, ?1, ?2, ?3, ?4)",
        )
        .bind(&account.provider)
        .bind(&account.subject_id)
        .bind(&account.login)
        .bind(to_unix_seconds(now))
        .execute(self.pool())
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};

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

    #[tokio::test]
    async fn an_unclaimed_panel_has_no_binding() {
        let store = Store::open_in_memory().await.expect("store");

        assert!(store.owner_binding().await.expect("binding").is_none());
    }

    #[tokio::test]
    async fn binding_records_the_identity_and_the_login_it_read() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;

        store.bind_owner(&ada, at(11)).await.expect("bind");
        let binding = store
            .owner_binding()
            .await
            .expect("binding")
            .expect("the panel is claimed");

        assert_eq!(binding.subject_id, "4242");
        assert_eq!(binding.login, "ada");
        assert_eq!(binding.bound_at, at(11));
        assert!(binding.matches(&ada));
    }

    /// The binding is the answer to "who owns this panel", so a second claim
    /// must not be able to take it over.
    #[tokio::test]
    async fn a_second_claim_never_displaces_the_first() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;
        let impostor = account(&store, "grace", "99").await;

        store.bind_owner(&ada, at(11)).await.expect("first");
        store.bind_owner(&impostor, at(12)).await.expect("second");

        let binding = store
            .owner_binding()
            .await
            .expect("binding")
            .expect("the panel is claimed");

        assert_eq!(binding.subject_id, "4242");
        assert!(!binding.matches(&impostor));
    }

    /// GitHub frees a login when its owner renames, and anyone may then take
    /// it. The binding has to survive that, which is the whole point of keying
    /// it on the subject id.
    #[tokio::test]
    async fn a_reused_login_does_not_match_the_binding() {
        let store = Store::open_in_memory().await.expect("store");
        let ada = account(&store, "ada", "4242").await;
        store.bind_owner(&ada, at(11)).await.expect("bind");

        // The real owner renames, then a stranger registers the freed login.
        account(&store, "ada-lovelace", "4242").await;
        let stranger = account(&store, "ada", "7777").await;

        let binding = store
            .owner_binding()
            .await
            .expect("binding")
            .expect("the panel is claimed");

        assert!(!binding.matches(&stranger));
        assert_eq!(binding.login, "ada", "the recorded login is only a label");
    }
}
