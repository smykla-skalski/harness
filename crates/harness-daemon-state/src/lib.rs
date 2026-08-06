//! The daemon's full on-disk state: [`harness_daemon_root`]'s manifest, lock,
//! ownership, and audit primitives, plus the identity, legacy-migration, and
//! task-board runtime-config surface that only the full daemon binary needs.
//!
//! Kept separate from `harness-daemon-root` because the config layer pulls in
//! `harness-task-board`'s git-runtime types, which `harness-bridge` has no
//! reason to depend on; the bridge binary depends on `harness-daemon-root`
//! directly instead.

mod config;
mod config_migration;
mod identity;
mod migration;
mod wake_event;

#[cfg(test)]
mod tests;

pub use harness_daemon_root::*;
pub use wake_event::{WakeEventLevel, record_wake_event};

pub use identity::{
    DAEMON_HOST_FINGERPRINT_ENV, DAEMON_NAME_ENV, DaemonIdentity, ensure_daemon_identity,
    reported_daemon_identity, set_daemon_name,
};
pub use migration::{
    LegacyDaemonRootMigration, MigrationDecision, migrate_legacy_daemon_root_at,
    migrate_legacy_daemon_root_for_current_process,
};

pub use config::{
    DaemonRuntimeConfig, VALID_LOG_LEVELS, load_persisted_log_level, load_runtime_config,
    parse_log_level, persist_log_level, replace_task_board_git_runtime_secrets,
    replace_task_board_github_tokens, replace_task_board_openrouter_token,
    task_board_github_repository_token, task_board_github_token, task_board_openrouter_token,
};
// Only the full daemon build (or this crate's own tests) calls these: the
// task-board runtime-config accessors that back the daemon's HTTP routes and
// the one-time legacy secret-envelope migration. See this crate's
// `daemon-runtime` feature.
#[cfg(any(test, feature = "daemon-runtime"))]
pub use config::{
    load_runtime_config_raw, overlay_task_board_git_runtime_profile_secrets,
    overlay_task_board_git_runtime_secret_flags, overlay_task_board_git_runtime_secrets,
    retaining_task_board_git_runtime_secrets,
};
#[cfg(any(test, feature = "daemon-runtime"))]
pub use config_migration::{
    remove_migrated_task_board_config_after_ack, remove_migrated_task_board_config_if_safe,
    task_board_git_runtime_secret_handoff_digest,
};
// `harness-daemon`'s own tests depend on this crate as an ordinary library
// and so never see its `cfg(test)` items; see this crate's `test-support`
// feature.
#[cfg(any(test, feature = "test-support"))]
pub use config::{
    load_task_board_git_runtime_config, persist_task_board_git_runtime_config,
    task_board_git_runtime_profile,
};
