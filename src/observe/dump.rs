mod execute;
mod format;

pub(crate) use execute::execute_dump;
pub(crate) use format::{format_dump_block, timestamp_suffix, tool_result_text};

pub(super) struct DumpOptions<'a> {
    pub from_line: usize,
    pub to_line: Option<usize>,
    pub text_filter: Option<&'a str>,
    pub roles: Option<&'a str>,
    pub tool_name: Option<&'a str>,
    pub raw_json: bool,
}
