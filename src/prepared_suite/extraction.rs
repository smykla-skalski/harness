fn extract_section<'a>(body: &'a str, heading: &str) -> Option<&'a str> {
    let pattern = format!("## {heading}");
    let mut start = None;
    let mut offset = 0;

    for line in body.split_inclusive('\n') {
        let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
        if let Some(section_start) = start {
            if trimmed.starts_with("## ") {
                return Some(body[section_start..offset].trim_end_matches(['\n', '\r']));
            }
        } else if trimmed == pattern || trimmed.starts_with(&format!("{pattern} ")) {
            start = Some(offset + line.len());
        }
        offset += line.len();
    }

    start.map(|section_start| body[section_start..].trim_end_matches(['\n', '\r']))
}

/// Extract the Configure section from a group body.
#[must_use]
pub fn configure_section(body: &str) -> Option<&str> {
    extract_section(body, "Configure")
}

/// Extract the Consume section from a group body.
#[must_use]
pub fn consume_section(body: &str) -> Option<&str> {
    extract_section(body, "Consume")
}

fn extract_fenced_blocks(text: &str, lang_prefixes: &[&str]) -> Vec<String> {
    let mut blocks = Vec::new();
    let mut fence_backticks: usize = 0;
    let mut current_block = Vec::new();

    for line in text.lines() {
        if fence_backticks > 0 {
            let closing_len = line.len() - line.trim_start_matches('`').len();
            if closing_len >= fence_backticks && line.trim_start_matches('`').trim().is_empty() {
                let joined = current_block.join("\n");
                let trimmed = joined.trim();
                if !trimmed.is_empty() {
                    blocks.push(format!("{trimmed}\n"));
                }
                current_block.clear();
                fence_backticks = 0;
            } else {
                current_block.push(line);
            }
        } else if line.starts_with("```") {
            let backtick_len = line.len() - line.trim_start_matches('`').len();
            let tag = &line[backtick_len..];
            let lang = tag.split_whitespace().next().unwrap_or("");
            if lang_prefixes.iter().any(|p| lang.eq_ignore_ascii_case(p)) {
                fence_backticks = backtick_len;
                current_block.clear();
            }
        }
    }
    blocks
}

/// Extract YAML code blocks from text.
#[must_use]
pub fn yaml_blocks(text: &str) -> Vec<String> {
    extract_fenced_blocks(text, &["yaml", "yml"])
}

/// Extract shell code blocks from text.
#[must_use]
pub fn shell_blocks(text: &str) -> Vec<String> {
    extract_fenced_blocks(text, &["bash", "sh"])
}
