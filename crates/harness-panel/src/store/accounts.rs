//! Everyone who has signed in to the panel.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::Row;
use sqlx::sqlite::SqliteRow;

use super::{Store, from_unix_seconds, to_unix_seconds};

/// The external identity a sign-in produced, before it is stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountIdentity {
    pub provider: String,
    pub subject_id: String,
    pub login: String,
    pub display_name: String,
    pub avatar_url: Option<String>,
}

/// A stored account, in the shape the panel's API returns it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Account {
    pub id: String,
    pub provider: String,
    pub subject_id: String,
    pub login: String,
    pub display_name: String,
    pub avatar_url: Option<String>,
    pub first_seen_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
}

impl Store {
    /// Record a sign-in, creating the account the first time and refreshing the
    /// renameable fields afterwards.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the write fails.
    pub async fn upsert_account(
        &self,
        identity: &AccountIdentity,
        now: DateTime<Utc>,
    ) -> Result<Account, sqlx::Error> {
        let timestamp = to_unix_seconds(now);
        let row = sqlx::query(
            "INSERT INTO accounts \
             (id, provider, subject_id, login, display_name, avatar_url, first_seen_at, \
              last_seen_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7) \
             ON CONFLICT (provider, subject_id) DO UPDATE SET \
               login = excluded.login, \
               display_name = excluded.display_name, \
               avatar_url = excluded.avatar_url, \
               last_seen_at = excluded.last_seen_at \
             RETURNING id, provider, subject_id, login, display_name, avatar_url, \
                       first_seen_at, last_seen_at",
        )
        // A returning account keeps the id it was created with, because
        // `excluded.id` is only applied on insert. Sessions and, later,
        // approvals reference it, so it has to stay stable across renames.
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(&identity.provider)
        .bind(&identity.subject_id)
        .bind(&identity.login)
        .bind(&identity.display_name)
        .bind(identity.avatar_url.as_deref())
        .bind(timestamp)
        .fetch_one(self.pool())
        .await?;

        Ok(account_from_row(&row))
    }

    /// Look an account up by its panel id.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the query fails.
    pub async fn account_by_id(&self, id: &str) -> Result<Option<Account>, sqlx::Error> {
        let row = sqlx::query(
            "SELECT id, provider, subject_id, login, display_name, avatar_url, first_seen_at, \
                    last_seen_at \
             FROM accounts WHERE id = ?1",
        )
        .bind(id)
        .fetch_optional(self.pool())
        .await?;

        Ok(row.as_ref().map(account_from_row))
    }

    /// Every account, most recently seen first.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the query fails.
    pub async fn list_accounts(&self) -> Result<Vec<Account>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT id, provider, subject_id, login, display_name, avatar_url, first_seen_at, \
                    last_seen_at \
             FROM accounts ORDER BY last_seen_at DESC, login ASC",
        )
        .fetch_all(self.pool())
        .await?;

        Ok(rows.iter().map(account_from_row).collect())
    }
}

pub(super) fn account_from_row(row: &SqliteRow) -> Account {
    Account {
        id: row.get("id"),
        provider: row.get("provider"),
        subject_id: row.get("subject_id"),
        login: row.get("login"),
        display_name: row.get("display_name"),
        avatar_url: row.get("avatar_url"),
        first_seen_at: from_unix_seconds(row.get("first_seen_at")),
        last_seen_at: from_unix_seconds(row.get("last_seen_at")),
    }
}

#[cfg(test)]
mod tests {
    use chrono::{Duration, TimeZone, Utc};

    use super::AccountIdentity;
    use crate::store::Store;

    fn ada() -> AccountIdentity {
        AccountIdentity {
            provider: "github:https://api.github.com".to_owned(),
            subject_id: "4242".to_owned(),
            login: "ada".to_owned(),
            display_name: "Ada Lovelace".to_owned(),
            avatar_url: Some("https://example.com/ada.png".to_owned()),
        }
    }

    fn at(hour: u32) -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 25, hour, 0, 0)
            .single()
            .expect("a valid timestamp")
    }

    #[tokio::test]
    async fn a_first_sign_in_creates_the_account() {
        let store = Store::open_in_memory().await.expect("store");

        let account = store.upsert_account(&ada(), at(10)).await.expect("upsert");

        assert_eq!(account.login, "ada");
        assert_eq!(account.first_seen_at, at(10));
        assert_eq!(account.last_seen_at, at(10));
        assert!(!account.id.is_empty());
    }

    /// A GitHub login can be renamed, and the panel identifies the person by
    /// the immutable subject id, so the second sign-in must update the same row
    /// rather than create a second account for one human.
    #[tokio::test]
    async fn a_renamed_login_updates_the_same_account() {
        let store = Store::open_in_memory().await.expect("store");
        let created = store.upsert_account(&ada(), at(10)).await.expect("first");

        let renamed = AccountIdentity {
            login: "ada-l".to_owned(),
            display_name: "Ada L".to_owned(),
            ..ada()
        };
        let updated = store
            .upsert_account(&renamed, at(12))
            .await
            .expect("second");

        assert_eq!(updated.id, created.id);
        assert_eq!(updated.login, "ada-l");
        assert_eq!(updated.display_name, "Ada L");
        assert_eq!(store.list_accounts().await.expect("list").len(), 1);
    }

    /// Sessions and, in the next slice, approvals hang off the account id, so
    /// a rename that changed it would silently detach them.
    #[tokio::test]
    async fn the_first_sign_in_timestamp_and_id_survive_later_sign_ins() {
        let store = Store::open_in_memory().await.expect("store");
        let created = store.upsert_account(&ada(), at(10)).await.expect("first");

        let updated = store.upsert_account(&ada(), at(14)).await.expect("second");

        assert_eq!(updated.id, created.id);
        assert_eq!(updated.first_seen_at, at(10));
        assert_eq!(updated.last_seen_at, at(14));
    }

    #[tokio::test]
    async fn two_people_get_two_accounts() {
        let store = Store::open_in_memory().await.expect("store");
        let grace = AccountIdentity {
            subject_id: "99".to_owned(),
            login: "grace".to_owned(),
            display_name: "Grace Hopper".to_owned(),
            avatar_url: None,
            ..ada()
        };

        store.upsert_account(&ada(), at(10)).await.expect("ada");
        store.upsert_account(&grace, at(11)).await.expect("grace");

        let accounts = store.list_accounts().await.expect("list");

        assert_eq!(accounts.len(), 2);
        // Most recently seen first, so an owner opening the page sees whoever
        // just signed in without scrolling.
        assert_eq!(accounts[0].login, "grace");
        assert_eq!(accounts[1].login, "ada");
    }

    /// GitHub's numeric id is unique only within one installation. Reusing a
    /// state directory against GHES must not turn an equal id into the account
    /// that signed in through github.com.
    #[tokio::test]
    async fn equal_subjects_from_different_installations_get_two_accounts() {
        let store = Store::open_in_memory().await.expect("store");
        let enterprise = AccountIdentity {
            provider: "github:https://ghe.example.com".to_owned(),
            ..ada()
        };

        let github = store.upsert_account(&ada(), at(10)).await.expect("github");
        let ghes = store
            .upsert_account(&enterprise, at(11))
            .await
            .expect("enterprise");

        assert_ne!(github.id, ghes.id);
        assert_eq!(store.list_accounts().await.expect("list").len(), 2);
    }

    #[tokio::test]
    async fn an_account_is_found_by_its_id() {
        let store = Store::open_in_memory().await.expect("store");
        let created = store.upsert_account(&ada(), at(10)).await.expect("upsert");

        let found = store
            .account_by_id(&created.id)
            .await
            .expect("lookup")
            .expect("the account exists");

        assert_eq!(found, created);
        assert!(
            store
                .account_by_id("absent")
                .await
                .expect("lookup")
                .is_none()
        );
    }

    #[tokio::test]
    async fn a_timestamp_survives_the_round_trip_to_storage() {
        let store = Store::open_in_memory().await.expect("store");
        let later = at(10) + Duration::seconds(37);

        let account = store.upsert_account(&ada(), later).await.expect("upsert");

        assert_eq!(account.last_seen_at, later);
    }
}
