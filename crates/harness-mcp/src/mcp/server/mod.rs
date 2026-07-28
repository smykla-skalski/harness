//! MCP server core: async transport loop that reads JSON-RPC messages,
//! dispatches to a handler, and writes responses back.

mod incoming;
mod transport;

#[cfg(test)]
mod tests;

pub use incoming::IncomingMessage;
pub use transport::{RequestHandler, serve};
