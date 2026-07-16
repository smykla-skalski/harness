use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};

const DELIMITER: &str = "\n\n";
const COMMENT_OPEN: &str = "<!--";
const RESERVED_STEM: &str = "harness-task-board-create";
const MARKER_PREFIX: &str = "<!-- harness-task-board-create:v1:";
const MARKER_SUFFIX: &str = " -->";

pub(super) fn render_body(body: &str, create_key: &str) -> Result<String, CliError> {
    let create_key = parse_canonical_key(create_key)?;
    reject_terminal_reserved(body, "user body already ends with reserved evidence")?;
    Ok(format!(
        "{body}{DELIMITER}{MARKER_PREFIX}{create_key}{MARKER_SUFFIX}"
    ))
}

pub(super) fn extract_from_body(body: &mut String) -> Result<Option<String>, CliError> {
    let Some(evidence) = terminal_reserved(body) else {
        return Ok(None);
    };
    if evidence.has_trailing_whitespace {
        return Err(marker_error(
            "must be byte-terminal without trailing whitespace",
        ));
    }
    let create_key = parse_marker(evidence.comment)?;
    let encoded_prefix = &body[..evidence.start];
    let user_body = encoded_prefix
        .strip_suffix(DELIMITER)
        .ok_or_else(|| marker_error("must be preceded by the canonical delimiter"))?;
    reject_terminal_reserved(user_body, "contains duplicate terminal reserved evidence")?;
    let cleaned = user_body.to_owned();
    *body = cleaned;
    Ok(Some(create_key))
}

fn parse_marker(comment: &str) -> Result<String, CliError> {
    let create_key = comment
        .strip_prefix(MARKER_PREFIX)
        .and_then(|value| value.strip_suffix(MARKER_SUFFIX))
        .ok_or_else(|| marker_error("is not canonical"))?;
    parse_canonical_key(create_key)
}

fn parse_canonical_key(create_key: &str) -> Result<String, CliError> {
    let parsed = Uuid::parse_str(create_key)
        .map_err(|error| marker_error(format!("has an invalid create key: {error}")))?;
    let canonical = parsed.hyphenated().to_string();
    if create_key != canonical {
        return Err(marker_error("create key is not canonical"));
    }
    Ok(canonical)
}

fn reject_terminal_reserved(body: &str, detail: &str) -> Result<(), CliError> {
    if terminal_reserved(body).is_some() {
        return Err(marker_error(detail));
    }
    Ok(())
}

fn terminal_reserved(body: &str) -> Option<TerminalReserved<'_>> {
    let trimmed = body.trim_end_matches(char::is_whitespace);
    for (start, _) in trimmed.rmatch_indices(COMMENT_OPEN) {
        let comment = &trimmed[start..];
        if reserved_comment(comment)
            && comment
                .find("-->")
                .is_none_or(|close| close + "-->".len() == comment.len())
        {
            return Some(TerminalReserved {
                start,
                comment,
                has_trailing_whitespace: trimmed.len() != body.len(),
            });
        }
    }
    None
}

fn reserved_comment(comment: &str) -> bool {
    let content = comment
        .strip_prefix(COMMENT_OPEN)
        .unwrap_or(comment)
        .trim_start_matches(char::is_whitespace);
    let Some(stem) = content.get(..RESERVED_STEM.len()) else {
        return false;
    };
    if !stem.eq_ignore_ascii_case(RESERVED_STEM) {
        return false;
    }
    content[RESERVED_STEM.len()..]
        .chars()
        .next()
        .is_none_or(|next| next == ':' || next.is_whitespace())
}

fn marker_error(detail: impl Into<String>) -> CliError {
    CliErrorKind::workflow_parse(format!("task-board github create marker {}", detail.into()))
        .into()
}

struct TerminalReserved<'a> {
    start: usize,
    comment: &'a str,
    has_trailing_whitespace: bool,
}

#[cfg(test)]
mod tests;
