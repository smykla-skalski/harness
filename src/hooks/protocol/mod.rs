pub mod context;
pub mod output;
pub mod payloads;
pub mod result;

// `hook_result` is defined under `errors` because `errors::hook_message`
// renders into it; keeping the type here would make the error layer depend on
// the hook layer.
pub use crate::errors::hook_result;
