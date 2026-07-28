/// Minimum text length to bother displaying in dump mode.
pub const MIN_DUMP_TEXT_LENGTH: usize = 5;

/// Maximum characters shown per dump line.
pub const DUMP_TRUNCATE_LENGTH: usize = 500;

/// Maximum characters stored in issue detail fields.
const MAX_DETAIL_LENGTH: usize = 2000;

/// Truncate text to at most `max_len` bytes at a valid UTF-8 char boundary.
#[must_use]
pub fn truncate_at(text: &str, max_len: usize) -> &str {
    if text.len() <= max_len {
        text
    } else {
        &text[..text.floor_char_boundary(max_len)]
    }
}

/// Cap issue detail text at construction time.
#[must_use]
pub fn truncate_details(text: &str) -> String {
    truncate_at(text, MAX_DETAIL_LENGTH).to_string()
}

/// Redact absolute paths and env var values from details text.
#[must_use]
pub fn redact_details(text: &str) -> String {
    use std::sync::LazyLock;

    static HOME_PATH_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"/(?:Users|home)/[^/\s]+/").expect("valid regex"));
    static ENV_VALUE_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"([A-Z_]{3,})=\S+").expect("valid regex"));

    let redacted = HOME_PATH_RE.replace_all(text, "<home>/");
    ENV_VALUE_RE
        .replace_all(&redacted, "$1=<redacted>")
        .into_owned()
}
