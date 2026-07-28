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
