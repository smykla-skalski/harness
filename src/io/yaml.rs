use crate::errors::{CliError, CliErrorKind};

/// Extract raw frontmatter YAML text and body from a markdown document.
///
/// Splits on the first `---\n ... \n---` delimiters using plain string
/// operations. Returns `(yaml_text, body)`.
///
/// # Errors
/// Returns `CliError` if frontmatter is missing or unterminated.
pub fn extract_raw_frontmatter(text: &str) -> Result<(String, String), CliError> {
    if !text.starts_with("---\n") {
        return Err(CliErrorKind::MissingFrontmatter.into());
    }

    let after_open = 4; // length of "---\n"
    let Some(close_pos) = text[after_open..].find("\n---") else {
        return Err(CliErrorKind::UnterminatedFrontmatter.into());
    };

    let yaml_text = &text[after_open..after_open + close_pos];

    // Body starts after the closing "---" and any leading newlines.
    let after_close = after_open + close_pos + 4; // length of "\n---"
    let body = text.get(after_close..).unwrap_or("");
    let body = body.trim_start_matches('\n');

    Ok((yaml_text.to_string(), body.to_string()))
}
