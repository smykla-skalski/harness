//! The panel's own `SQLite` database.
//!
//! Timestamps are stored as Unix seconds rather than RFC 3339 text because
//! expiry is decided in SQL, and text comparison would depend on every writer
//! agreeing about fractional digits and zone spelling.

pub mod accounts;
pub mod approvals;
pub mod oauth;
pub mod owner;
pub mod sessions;
pub mod token;

use std::fs;
use std::path::Path;
use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use sqlx::{Sqlite, SqlitePool};

use crate::error::PanelError;

static PANEL_MIGRATOR: Migrator = sqlx::migrate!("./migrations");

const BUSY_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: u32 = 8;

/// Handle on the panel's account, session, and sign-in state.
#[derive(Debug, Clone)]
pub struct Store {
    pool: SqlitePool,
}

impl Store {
    /// Open the database under `state_dir`, creating and migrating it.
    ///
    /// # Errors
    /// Returns [`PanelError::Io`] when the state directory cannot be created,
    /// and [`PanelError::Storage`] or [`PanelError::Migration`] when the
    /// database cannot be opened or brought up to date.
    pub async fn open(state_dir: &Path) -> Result<Self, PanelError> {
        fs::create_dir_all(state_dir).map_err(|error| {
            PanelError::io("creating the panel state directory", state_dir, error)
        })?;
        restrict_state_directory(state_dir)?;

        let database = state_dir.join("panel.sqlite3");
        let options = SqliteConnectOptions::new()
            .filename(&database)
            .create_if_missing(true)
            .foreign_keys(true)
            .journal_mode(SqliteJournalMode::Wal)
            .synchronous(SqliteSynchronous::Normal)
            .busy_timeout(BUSY_TIMEOUT);

        Self::from_options(options).await
    }

    /// Open a private in-memory database, for tests.
    ///
    /// # Errors
    /// Returns [`PanelError::Storage`] or [`PanelError::Migration`] when the
    /// database cannot be opened or migrated.
    pub async fn open_in_memory() -> Result<Self, PanelError> {
        let options = SqliteConnectOptions::new()
            .in_memory(true)
            .shared_cache(true)
            .foreign_keys(true);
        // Every connection to `:memory:` is its own database, so the pool has to
        // keep exactly one or the migrated schema disappears between queries.
        Self::from_pool(
            SqlitePoolOptions::new()
                .max_connections(1)
                .connect_with(options)
                .await?,
        )
        .await
    }

    async fn from_options(options: SqliteConnectOptions) -> Result<Self, PanelError> {
        let pool = SqlitePoolOptions::new()
            .max_connections(MAX_CONNECTIONS)
            .min_connections(1)
            .connect_with(options)
            .await?;
        Self::from_pool(pool).await
    }

    async fn from_pool(pool: sqlx::Pool<Sqlite>) -> Result<Self, PanelError> {
        PANEL_MIGRATOR.run(&pool).await?;
        Ok(Self { pool })
    }

    #[must_use]
    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    /// Drop sessions and unfinished sign-ins that have expired.
    ///
    /// Expiry is enforced on every read, so this only reclaims rows; nothing
    /// depends on it having run.
    ///
    /// # Errors
    /// Returns [`sqlx::Error`] when the deletes fail.
    pub async fn prune_expired(&self, now: DateTime<Utc>) -> Result<u64, sqlx::Error> {
        let cutoff = to_unix_seconds(now);
        let sessions = sqlx::query("DELETE FROM sessions WHERE expires_at <= ?1")
            .bind(cutoff)
            .execute(&self.pool)
            .await?
            .rows_affected();
        let states = sqlx::query("DELETE FROM oauth_states WHERE expires_at <= ?1")
            .bind(cutoff)
            .execute(&self.pool)
            .await?
            .rows_affected();
        Ok(sessions + states)
    }
}

#[cfg(unix)]
fn restrict_state_directory(path: &Path) -> Result<(), PanelError> {
    use std::os::unix::fs::PermissionsExt;

    // The database holds session hashes and every account that has signed in,
    // so it must not be readable by other users on the host.
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .map_err(|error| PanelError::io("restricting the panel state directory", path, error))
}

#[cfg(not(unix))]
fn restrict_state_directory(_path: &Path) -> Result<(), PanelError> {
    Ok(())
}

#[must_use]
pub fn to_unix_seconds(value: DateTime<Utc>) -> i64 {
    value.timestamp()
}

/// Rebuild a timestamp read back from the database.
///
/// A row written by this crate always round-trips; a value outside the range
/// `chrono` can represent could only come from a hand-edited database, and
/// clamping is more useful there than refusing to serve the page.
///
/// The clamp is to the end of the representable range it fell off, never to the
/// current time. Substituting "now" would make one stored row render as a
/// different instant on every read, so the same account would appear to have
/// been seen at a new moment each time anyone loaded the page.
#[must_use]
pub fn from_unix_seconds(value: i64) -> DateTime<Utc> {
    Utc.timestamp_opt(value, 0).single().unwrap_or({
        if value.is_negative() {
            DateTime::<Utc>::MIN_UTC
        } else {
            DateTime::<Utc>::MAX_UTC
        }
    })
}

#[cfg(test)]
mod tests {
    use super::{Store, from_unix_seconds, to_unix_seconds};
    use chrono::{DateTime, Duration, Utc};

    #[tokio::test]
    async fn opening_creates_and_migrates_the_schema() {
        let directory = tempfile::tempdir().expect("temp dir");

        let store = Store::open(directory.path()).await.expect("open the store");

        let tables: Vec<(String,)> =
            sqlx::query_as("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .fetch_all(store.pool())
                .await
                .expect("listing tables");
        let names: Vec<&str> = tables.iter().map(|(name,)| name.as_str()).collect();

        for expected in ["accounts", "oauth_states", "sessions"] {
            assert!(names.contains(&expected), "missing {expected} in {names:?}");
        }
        assert!(directory.path().join("panel.sqlite3").exists());
    }

    /// Opening the same directory twice is what a restart does, and a migrator
    /// that re-ran its first migration would fail on the second start.
    #[tokio::test]
    async fn opening_twice_is_safe() {
        let directory = tempfile::tempdir().expect("temp dir");

        let first = Store::open(directory.path()).await.expect("first open");
        drop(first);
        Store::open(directory.path()).await.expect("second open");
    }

    #[test]
    fn timestamps_round_trip_through_unix_seconds() {
        let now = Utc::now();

        assert_eq!(
            from_unix_seconds(to_unix_seconds(now)).timestamp(),
            now.timestamp()
        );
    }

    /// A hand-edited row must render as the same instant every time it is read.
    /// Falling back to the current time instead would make one stored value
    /// look like a new sighting on every page load.
    #[test]
    fn an_unrepresentable_timestamp_clamps_to_a_stable_bound() {
        for value in [i64::MIN, i64::MAX] {
            assert_eq!(from_unix_seconds(value), from_unix_seconds(value));
        }

        assert_eq!(from_unix_seconds(i64::MIN), DateTime::<Utc>::MIN_UTC);
        assert_eq!(from_unix_seconds(i64::MAX), DateTime::<Utc>::MAX_UTC);
    }

    #[tokio::test]
    async fn pruning_an_empty_store_removes_nothing() {
        let store = Store::open_in_memory().await.expect("open the store");

        let removed = store
            .prune_expired(Utc::now() + Duration::days(1))
            .await
            .expect("prune");

        assert_eq!(removed, 0);
    }
}
