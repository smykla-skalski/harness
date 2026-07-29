//! `state` moved natively into `harness-daemon-root`, which this crate and
//! `harness-daemon` now both depend on directly instead of each compiling
//! their own copy of the same files through separate `#[path]` includes.

pub use harness_daemon_root::*;

// `agent_acp`'s OpenRouter token lookup needs the full daemon's task-board
// runtime config, gated the same way; the default `bridge-runtime` build has
// no reason to depend on it.
#[cfg(feature = "daemon-runtime")]
pub use harness_daemon_state::task_board_openrouter_token;
