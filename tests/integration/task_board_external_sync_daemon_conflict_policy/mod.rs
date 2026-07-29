//! Task-board external-sync conflict-policy coverage against a real daemon
//! database.
//!
//! Unlike the fake-HTTP-daemon routing suites, these tests exercise
//! `sync_external_tasks` directly against a live `AsyncDaemonDb` (a real
//! `SQLite` database in a tempdir), because the behavior under test is the
//! `TaskBoardSyncStore`/`TaskBoardExternalCreateStore` persistence path
//! itself: conflict rows, provider-exclusion tombstones, and pull-policy
//! resolution all read back through the database, not through the daemon's
//! HTTP API. Split by scenario group so no file grows past the repo's
//! line-count guideline; `support` holds the shared sync-client fixtures
//! every group file uses.

mod conflict_correctness;
mod provider_exclusion_status_filter;
mod pull_policy;
mod support;
