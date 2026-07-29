//! Task-board wire types the daemon namespace re-exports without owning.
//!
//! The types live in `crate::task_board`. This re-export stays because the MCP
//! tool surface compiles into the standalone `harness-mcp` crate as well, where
//! `crate::daemon::protocol` is the only namespace shared with this one, so
//! dropping it would break that crate while `harness` still compiled.

pub use crate::task_board::{
    PolicyPipelineMakeLiveRequest, PolicyPipelinePromoteRequest, PolicyPipelinePromoteResponse,
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitHubTokensSyncResponse, TaskBoardGitRuntimeConfig,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOpenRouterTokenSyncResponse,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorStatus,
};
