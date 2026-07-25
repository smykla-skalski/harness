//! Who the owner has allowed to generate a pairing link.
//!
//! The decision and the record of it are written together, so the panel cannot
//! end up able to pair with nothing explaining why, or carrying a trail that
//! claims a decision the accounts table never took.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::Row;

use super::accounts::Account;
use super::{Store, from_unix_seconds, to_unix_seconds};

/// One approval decision, kept after the fact.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ApprovalEvent {
    pub account_id: String,
    pub actor_id: String,
    /// The actor's login as it read when they decided. A label for whoever
    /// reads the trail later, not an identity: the id is that.
    pub actor_login: String,
    pub granted: bool,
    pub decided_at: DateTime<Utc>,
}

impl Store {
    /// Grant or withdraw an account's ability to pair.
    ///
    /// Returns `false` when no such account exists, which is what a stale page
    /// in the owner's browser produces.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the write fails.
    pub async fn set_can_pair(
        &self,
        account_id: &str,
        granted: bool,
        actor: &Account,
        now: DateTime<Utc>,
    ) -> Result<bool, sqlx::Error> {
        let mut transaction = self.pool().begin().await?;

        let updated = sqlx::query("UPDATE accounts SET can_pair = ?1 WHERE id = ?2")
            .bind(i64::from(granted))
            .bind(account_id)
            .execute(&mut *transaction)
            .await?
            .rows_affected();
        if updated == 0 {
            // Nothing to record: writing the event anyway would leave a trail
            // describing a decision about an account that does not exist.
            transaction.rollback().await?;
            return Ok(false);
        }

        sqlx::query(
            "INSERT INTO approval_events \
             (id, account_id, actor_id, actor_login, granted, decided_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(account_id)
        .bind(&actor.id)
        .bind(&actor.login)
        .bind(i64::from(granted))
        .bind(to_unix_seconds(now))
        .execute(&mut *transaction)
        .await?;

        transaction.commit().await?;
        Ok(true)
    }

    /// Every decision taken about an account, most recent first.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the query fails.
    pub async fn approval_history(
        &self,
        account_id: &str,
    ) -> Result<Vec<ApprovalEvent>, sqlx::Error> {
        let rows = sqlx::query(
            "SELECT account_id, actor_id, actor_login, granted, decided_at \
             FROM approval_events WHERE account_id = ?1 ORDER BY decided_at DESC, rowid DESC",
        )
        .bind(account_id)
        .fetch_all(self.pool())
        .await?;

        Ok(rows
            .iter()
            .map(|row| ApprovalEvent {
                account_id: row.get("account_id"),
                actor_id: row.get("actor_id"),
                actor_login: row.get("actor_login"),
                granted: row.get::<i64, _>("granted") != 0,
                decided_at: from_unix_seconds(row.get("decided_at")),
            })
            .collect())
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

    /// An account that appears between a deploy and the owner's next visit must
    /// not be quietly able to mint links.
    #[tokio::test]
    async fn a_new_account_cannot_pair() {
        let store = Store::open_in_memory().await.expect("store");

        let ada = account(&store, "ada", "4242").await;

        assert!(!ada.can_pair);
    }

    #[tokio::test]
    async fn granting_and_withdrawing_both_take_effect() {
        let store = Store::open_in_memory().await.expect("store");
        let owner = account(&store, "owner", "1").await;
        let ada = account(&store, "ada", "4242").await;

        assert!(
            store
                .set_can_pair(&ada.id, true, &owner, at(11))
                .await
                .expect("grant")
        );
        assert!(
            store
                .account_by_id(&ada.id)
                .await
                .expect("lookup")
                .expect("the account exists")
                .can_pair
        );

        assert!(
            store
                .set_can_pair(&ada.id, false, &owner, at(12))
                .await
                .expect("revoke")
        );
        assert!(
            !store
                .account_by_id(&ada.id)
                .await
                .expect("lookup")
                .expect("the account exists")
                .can_pair
        );
    }

    /// The trail is what answers "who allowed this person", so every decision
    /// has to leave one, in the order they were taken.
    #[tokio::test]
    async fn every_decision_is_recorded_with_its_actor() {
        let store = Store::open_in_memory().await.expect("store");
        let owner = account(&store, "owner", "1").await;
        let ada = account(&store, "ada", "4242").await;

        store
            .set_can_pair(&ada.id, true, &owner, at(11))
            .await
            .expect("grant");
        store
            .set_can_pair(&ada.id, false, &owner, at(12))
            .await
            .expect("revoke");

        let history = store.approval_history(&ada.id).await.expect("history");

        assert_eq!(history.len(), 2);
        assert!(!history[0].granted, "most recent first");
        assert_eq!(history[0].decided_at, at(12));
        assert!(history[1].granted);
        assert_eq!(history[1].actor_id, owner.id);
        assert_eq!(history[1].actor_login, "owner");
    }

    /// A stale page in the owner's browser names an account that is gone. It
    /// must not leave a trail describing a decision that never applied.
    #[tokio::test]
    async fn deciding_about_an_unknown_account_records_nothing() {
        let store = Store::open_in_memory().await.expect("store");
        let owner = account(&store, "owner", "1").await;

        assert!(
            !store
                .set_can_pair("absent", true, &owner, at(11))
                .await
                .expect("decision")
        );
        assert!(
            store
                .approval_history("absent")
                .await
                .expect("history")
                .is_empty()
        );
    }

    /// One person's approval is not another's.
    #[tokio::test]
    async fn approving_one_account_leaves_the_others_alone() {
        let store = Store::open_in_memory().await.expect("store");
        let owner = account(&store, "owner", "1").await;
        let ada = account(&store, "ada", "4242").await;
        let grace = account(&store, "grace", "99").await;

        store
            .set_can_pair(&ada.id, true, &owner, at(11))
            .await
            .expect("grant");

        assert!(
            !store
                .account_by_id(&grace.id)
                .await
                .expect("lookup")
                .expect("the account exists")
                .can_pair
        );
    }
}
