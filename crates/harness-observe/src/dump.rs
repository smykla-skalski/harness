mod execute;
mod format;

pub(crate) use execute::execute_dump;
pub(crate) use format::{format_dump_block, timestamp_suffix};
// Re-exported from `text` (always available) rather than defined here:
// `classifier` needs it unconditionally, so it can't live in a `cli`-gated
// module. This keeps `harness_observe::dump::tool_result_text` a stable path
// for whatever built this against the pre-split layout.
pub use crate::text::tool_result_text;

pub(crate) struct DumpOptions<'a> {
    pub from_line: usize,
    pub to_line: Option<usize>,
    pub text_filter: Option<&'a str>,
    pub roles: Option<&'a str>,
    pub tool_name: Option<&'a str>,
    pub raw_json: bool,
}
