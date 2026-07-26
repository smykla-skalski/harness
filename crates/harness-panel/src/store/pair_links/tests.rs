use chrono::{TimeZone, Utc};

use super::{PairLinkRecord, RESERVATION_PREFIX};
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

/// The daemon reports what it issued and nothing about who the panel issued
/// it for, so this map is the only thing that decides whose row a pairing
/// is and who may withdraw it.
#[tokio::test]
async fn every_recorded_link_names_the_account_it_was_minted_for() {
    let store = Store::open_in_memory().await.expect("store");
    let ada = account(&store, "ada", "4242").await;
    let grace = account(&store, "grace", "99").await;
    store
        .record_pair_link(&record("pair-1", &ada.id, 11))
        .await
        .expect("first");
    store
        .record_pair_link(&record("pair-2", &grace.id, 12))
        .await
        .expect("second");

    let accounts = store.pair_link_accounts().await.expect("attribution");

    assert_eq!(accounts.get("pair-1"), Some(&ada.id));
    assert_eq!(accounts.get("pair-2"), Some(&grace.id));
    assert_eq!(
        store.pair_link_account("pair-1").await.expect("one link"),
        Some(ada.id)
    );
}

/// A reservation stands for a link the daemon never confirmed. It holds a
/// slot and nothing else, so attributing one would put a row on the page
/// for a pairing that does not exist, and answering a revoke about one
/// would let a caller that guessed the panel's internal spelling act on it.
#[tokio::test]
async fn a_reservation_is_never_attributed_to_anyone() {
    let store = Store::open_in_memory().await.expect("store");
    let ada = account(&store, "ada", "4242").await;
    let held = format!("{RESERVATION_PREFIX}abcd");
    store
        .reserve_pair_link(&record(&held, &ada.id, 11), 5, at(11))
        .await
        .expect("reservation");

    assert!(
        store
            .pair_link_accounts()
            .await
            .expect("attribution")
            .is_empty()
    );
    assert_eq!(
        store.pair_link_account(&held).await.expect("lookup"),
        None,
        "a caller naming a reservation must not be told whose it is"
    );
}

/// A pairing the panel has no row for belongs to nobody it can name. The
/// mint path records one before it answers and shouts when it cannot, so
/// this is the case where that write failed — and inventing an owner for it
/// would hand one account another's device.
#[tokio::test]
async fn an_unrecorded_pairing_is_attributed_to_nobody() {
    let store = Store::open_in_memory().await.expect("store");
    account(&store, "ada", "4242").await;

    assert_eq!(
        store
            .pair_link_account("pair-the-panel-never-wrote-down")
            .await
            .expect("lookup"),
        None
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
