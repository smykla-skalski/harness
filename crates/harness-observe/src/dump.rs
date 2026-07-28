mod execute;
mod format;

pub(crate) use execute::execute_dump;
pub(crate) use format::{format_dump_block, timestamp_suffix};

pub(crate) struct DumpOptions<'a> {
    pub from_line: usize,
    pub to_line: Option<usize>,
    pub text_filter: Option<&'a str>,
    pub roles: Option<&'a str>,
    pub tool_name: Option<&'a str>,
    pub raw_json: bool,
}

/// Extract text from a `tool_result` content block.
#[must_use]
pub fn tool_result_text(block: &serde_json::Value) -> String {
    let content = &block["content"];
    if let Some(arr) = content.as_array() {
        let parts: Vec<&str> = arr
            .iter()
            .filter_map(|item| {
                if item["type"].as_str() == Some("text") {
                    item["text"].as_str()
                } else {
                    None
                }
            })
            .collect();
        parts.join("\n")
    } else if let Some(s) = content.as_str() {
        s.to_string()
    } else {
        String::new()
    }
}
