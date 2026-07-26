mod api_contract;
mod audit;
mod binding;
mod openrouter_models;
mod reviews;
mod summaries;
mod task_board;
#[cfg(test)]
mod tests;
mod voice;
mod websocket;

pub use api_contract::*;
pub use audit::*;
pub use binding::{
    ControlPlaneActorRequest, bind_control_plane_actor_value, current_control_plane_actor_id,
    with_control_plane_actor,
};
pub use harness_protocol::managed_agents::codex::*;
pub use openrouter_models::*;
pub use reviews::*;
pub use summaries::*;
// The wire contracts below describe the session and task-board domains and now
// live with them, but they keep being re-exported here as well because the MCP
// tool surface compiles into the standalone `harness-mcp` crate too, where the
// only namespace shared with this one is `crate::daemon::protocol`.
pub use crate::session::wire::*;
pub use crate::task_board::item_query_bounds::{
    TASK_BOARD_LIST_DEFAULT_LIMIT, TASK_BOARD_LIST_MAX_CURSOR_CHARS, TASK_BOARD_LIST_MAX_LIMIT,
    TASK_BOARD_LIST_MAX_QUERY_CHARS, TASK_BOARD_LIST_MAX_TAGS,
};
pub use crate::task_board::wire::*;
pub use task_board::*;
pub use voice::*;
pub use websocket::*;
