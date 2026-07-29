// Deliberate public API facade, not scaffolding: `crate::task_board::types`,
// `item_fields`, `item_query`, `lane`, `policy`, `git_identity_defaults`,
// `progress_rollup`, `remote_spki_pin`, `runtime_config`, `store`, `machines`,
// part of `wire`, `project`/`project_color`/`project_shape`, `triage*`,
// `prompt*`/`worker_prompt`, `working_copy`, `policy_graph`, `policy_runtime`,
// `automation`, `dispatch`/`evaluation`/`planning`, `github::config`'s whole
// GitHub automation-settings wire-type module, and now
// `orchestrator`/`summary`/`legacy_import` moved into the standalone
// `harness-task-board` crate. Every other task-board subtree below reaches
// those through this glob re-export exactly the way external callers
// (`daemon`, `session`, `hooks`) already do, so none of them needed an
// import change for the move.
pub use harness_task_board::*;

pub mod external;
pub mod github;
pub mod transport;
pub mod wire;

pub use external::{
    ExternalCreateOutcome, ExternalProvider, ExternalProviderCapabilities, ExternalRevisionUpdate,
    ExternalSyncAction, ExternalSyncClient, ExternalSyncConfig, ExternalSyncConflictPolicy,
    ExternalSyncDirection, ExternalSyncField, ExternalSyncOperation, ExternalSyncOptions,
    ExternalTask, ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome, GH_TOKEN_ENV,
    GITHUB_REPOSITORY_ENV, GitHubInboxSyncClient, GitHubSyncClient, HARNESS_GITHUB_REPOSITORY_ENV,
    HARNESS_GITHUB_TOKEN_ENV, ProviderExclusionAuditContext, ProviderExclusionRestoreOutcome,
    configured_sync_clients,
};
// `sync_external_tasks` has no production call site left in this crate now
// that `daemon::service` compiles natively in `harness-daemon` instead of
// mirroring in here: root's own `external::tests` (and `sync_tests`) are the
// only remaining callers.
#[cfg(test)]
pub(crate) use external::sync_external_tasks;
