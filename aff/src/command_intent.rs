use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedCommand {
    words: Vec<String>,
}

impl ParsedCommand {
    pub fn parse(text: &str) -> Result<Self, shell_words::ParseError> {
        Ok(Self {
            words: shell_words::split(text)?,
        })
    }

    #[must_use]
    pub fn words(&self) -> &[String] {
        &self.words
    }
}

pub fn parse_supported_command_text(
    text: &str,
    boundary: &'static str,
) -> Result<ParsedCommand, String> {
    let parsed = ParsedCommand::parse(text)
        .map_err(|error| format!("failed to parse command text: {error}"))?;
    validate_supported_text(text, boundary)?;
    Ok(parsed)
}

#[must_use]
pub fn is_shell_control_op(s: &str) -> bool {
    matches!(s, "&&" | "||" | ";" | "|" | "&")
}

#[must_use]
pub fn is_env_assignment(word: &str) -> bool {
    if let Some(eq_pos) = word.find('=') {
        if eq_pos == 0 {
            return false;
        }
        let prefix = &word[..eq_pos];
        prefix
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
            && prefix
                .chars()
                .next()
                .is_some_and(|ch| ch.is_ascii_alphabetic() || ch == '_')
    } else {
        false
    }
}

#[must_use]
pub fn normalized_binary_name(raw: &str) -> String {
    let stripped = strip_shell_wrappers(raw.trim());

    Path::new(&stripped).file_name().map_or_else(
        || stripped.to_lowercase(),
        |name| name.to_string_lossy().to_lowercase(),
    )
}

fn strip_shell_wrappers(raw: &str) -> String {
    if raw.len() >= 2 && raw.starts_with('`') && raw.ends_with('`') {
        return strip_shell_wrappers(&raw[1..raw.len() - 1]);
    }
    if let Some(inner) = raw
        .strip_prefix("${")
        .and_then(|rest| rest.strip_suffix('}'))
    {
        return strip_shell_wrappers(inner);
    }
    if let Some(inner) = raw
        .strip_prefix('$')
        .filter(|candidate| is_plain_shell_variable(candidate))
    {
        return strip_shell_wrappers(inner);
    }
    if let Some(inner) = fully_wrapped_subshell(raw) {
        return strip_shell_wrappers(inner);
    }
    raw.to_string()
}

fn is_plain_shell_variable(candidate: &str) -> bool {
    !candidate.is_empty()
        && candidate
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
}

fn fully_wrapped_subshell(raw: &str) -> Option<&str> {
    let inner = raw.strip_prefix("$(")?.strip_suffix(')')?;
    let mut depth = 1_u32;

    for character in inner.chars() {
        match character {
            '(' => depth += 1,
            ')' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return None;
                }
            }
            _ => {}
        }
    }

    (depth == 1).then_some(inner)
}

fn validate_supported_text(text: &str, boundary: &'static str) -> Result<(), String> {
    if has_unsupported_embedded_control_operator(text) {
        return Err(format!(
            "unsupported {boundary} command shape: shell control operators must be space-delimited"
        ));
    }
    Ok(())
}

fn has_unsupported_embedded_control_operator(text: &str) -> bool {
    let mut chars = text.char_indices().peekable();
    let mut in_single_quotes = false;
    let mut in_double_quotes = false;
    let mut escaped = false;

    while let Some((index, character)) = chars.next() {
        if escaped {
            escaped = false;
            continue;
        }

        match character {
            '\\' if !in_single_quotes => {
                escaped = true;
                continue;
            }
            '\'' if !in_double_quotes => {
                in_single_quotes = !in_single_quotes;
                continue;
            }
            '"' if !in_single_quotes => {
                in_double_quotes = !in_double_quotes;
                continue;
            }
            _ => {}
        }

        if in_single_quotes || in_double_quotes {
            continue;
        }

        let operator_len = if text[index..].starts_with("&&") || text[index..].starts_with("||") {
            2
        } else if matches!(character, ';' | '|' | '&') {
            1
        } else {
            continue;
        };

        let prev_is_whitespace = text[..index]
            .chars()
            .next_back()
            .is_none_or(char::is_whitespace);
        let next_is_whitespace = text[index + operator_len..]
            .chars()
            .next()
            .is_none_or(char::is_whitespace);

        if !(prev_is_whitespace && next_is_whitespace) {
            return true;
        }

        if operator_len == 2 {
            chars.next();
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use super::{
        ParsedCommand, is_env_assignment, normalized_binary_name, parse_supported_command_text,
    };

    #[test]
    fn parsed_command_splits_words() {
        let parsed = ParsedCommand::parse("FOO=bar cargo test").expect("command parses");
        assert_eq!(parsed.words(), ["FOO=bar", "cargo", "test"]);
    }

    #[test]
    fn env_assignment_detection_matches_shell_style_assignments() {
        assert!(is_env_assignment("FOO=bar"));
        assert!(!is_env_assignment("=bar"));
    }

    #[test]
    fn normalized_binary_name_strips_shell_wrappers() {
        assert_eq!(normalized_binary_name("$(/usr/bin/CARGO)"), "cargo");
        assert_eq!(normalized_binary_name("`XCODEBUILD`"), "xcodebuild");
    }

    #[test]
    fn normalized_binary_name_keeps_partial_subshell_literals() {
        assert_eq!(normalized_binary_name("$(foo)bar"), "$(foo)bar");
    }

    #[test]
    fn supported_parser_rejects_embedded_control_operators() {
        let error = parse_supported_command_text("cargo test&&cargo check", "top-level")
            .expect_err("embedded control operator should fail");
        assert!(error.contains("unsupported top-level command shape"));
    }

    #[test]
    fn supported_parser_allows_quoted_urls_with_ampersands() {
        parse_supported_command_text("curl 'https://example.com?a=1&b=2'", "top-level")
            .expect("quoted URL should stay allowed");
    }
}
