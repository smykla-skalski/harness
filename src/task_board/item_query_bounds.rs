//! Bounds every task-board list read is held to.
//!
//! This file is deliberately free of `crate::` paths so the standalone
//! `harness-protocol` crate can `#[path]`-include it. The MCP tool advertises
//! these numbers in its input schema and the daemon enforces them, and the two
//! live in different crates, so a shared source file is the only way the
//! advertised bound cannot drift from the enforced one.

/// Page size used when a caller names none.
pub const TASK_BOARD_LIST_DEFAULT_LIMIT: u32 = 200;
/// Largest page a caller may ask for.
pub const TASK_BOARD_LIST_MAX_LIMIT: u32 = 500;
/// Longest accepted `query` text, in characters.
pub const TASK_BOARD_LIST_MAX_QUERY_CHARS: usize = 512;
/// Most facet tags one request may carry.
pub const TASK_BOARD_LIST_MAX_TAGS: usize = 16;
/// Longest accepted `cursor`, in characters.
///
/// A cursor the daemon issued is base64 over `offset:item_id`, so this leaves
/// room for an item id far longer than any the board mints while keeping a
/// caller from handing the decoder an arbitrary amount of work.
pub const TASK_BOARD_LIST_MAX_CURSOR_CHARS: usize = 512;
