//! Reviews wire types, relocated here from `harness-reviews`.
//!
//! `harness-daemon`'s `daemon::protocol::reviews` re-exports roughly 115
//! types from `harness-reviews` — verified pure-data, with inherent methods
//! that only touch `CliError`/`harness-kernel` (both already reachable from
//! this crate). `harness-reviews` already depends on `harness-protocol`, so
//! these types could not stay defined in `harness-reviews` and still let
//! `daemon::protocol::reviews` itself move here later without creating the
//! same dependency cycle #1054 hit doing the equivalent move for task-board
//! types. `harness-reviews` re-exports every name below unchanged, at the
//! same module paths it used to define them at, so this move changes no
//! public API and no runtime behavior.
//!
//! Five of the moved types embed `harness_task_board::github::GitHubMergeMethod`
//! directly. `harness-task-board` depends on `harness-protocol`, so this
//! crate cannot depend back on `harness-task-board` for that type without
//! cycling; `GitHubMergeMethod` is pure data with zero inherent methods, so
//! it moved alongside into [`github_merge_method`] instead, and
//! `harness-task-board::github_config` re-exports it from here unchanged.

pub mod avatar;
pub mod body_update;
pub mod enums;
pub mod file_comment;
pub mod files;
pub mod github_merge_method;
pub mod logic;
pub mod review_thread_resolve;
pub mod timeline;
pub mod types;
pub mod validation;
