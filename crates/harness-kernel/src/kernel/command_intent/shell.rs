use std::path::Path;

/// Returns `true` for shell control operators: `&&`, `||`, `;`, `|`, `&`.
#[must_use]
pub fn is_shell_control_op(s: &str) -> bool {
    matches!(s, "&&" | "||" | ";" | "|" | "&")
}

/// Returns `true` for shell chain operators: `&&`, `||`, `;`, `&`.
#[must_use]
pub fn is_shell_chain_op(s: &str) -> bool {
    matches!(s, "&&" | "||" | ";" | "&")
}

/// Returns `true` for shell redirect operators: `>`, `>>`, `1>`, `1>>`.
#[must_use]
pub fn is_shell_redirect_op(s: &str) -> bool {
    matches!(s, ">" | ">>" | "1>" | "1>>")
}

/// Returns `true` for shell flow keywords like `if`, `for`, `while`, etc.
#[must_use]
pub fn is_shell_flow_word(s: &str) -> bool {
    matches!(
        s,
        "case" | "do" | "done" | "esac" | "fi" | "for" | "if" | "then" | "until" | "while"
    )
}

/// Returns `true` when `word` is an environment variable assignment (`VAR=value`).
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

/// Strip subshell and backtick wrappers from a token.
///
/// Handles `$(cmd)`, nested `$($(cmd))`, split tokens like `$(kubectl`
/// and `kuma-system)`, and backtick wrappers.
fn strip_shell_wrappers(raw: &str) -> String {
    let mut stripped = raw.trim().to_string();

    loop {
        if let Some(inner) = stripped
            .strip_prefix("$(")
            .and_then(|rest| rest.strip_suffix(')'))
        {
            stripped = inner.to_string();
            continue;
        }
        if let Some(inner) = stripped.strip_prefix("$(") {
            stripped = inner.to_string();
            continue;
        }
        if stripped.ends_with(')') && !stripped.contains('(') {
            stripped = stripped[..stripped.len() - 1].to_string();
        }
        break;
    }

    if stripped.starts_with('`') {
        stripped = stripped.trim_start_matches('`').to_string();
    }
    if stripped.ends_with('`') {
        stripped = stripped.trim_end_matches('`').to_string();
    }

    stripped
}

/// Normalize a binary name: strip path prefix, `$` / `${...}` wrappers,
/// `$(...)` subshell wrappers, backtick wrappers, and lowercase.
#[must_use]
pub fn normalized_binary_name(raw: &str) -> String {
    let mut stripped = strip_shell_wrappers(raw);

    if let Some(inner) = stripped
        .strip_prefix("${")
        .and_then(|rest| rest.strip_suffix('}'))
    {
        stripped = inner.to_string();
    } else if let Some(stripped_var) = stripped.strip_prefix('$') {
        stripped = stripped_var.to_string();
    }

    Path::new(&stripped).file_name().map_or_else(
        || stripped.to_lowercase(),
        |name| name.to_string_lossy().to_lowercase(),
    )
}

/// Returns `true` when the raw command text contains subshell substitution
/// (`$(...)` or backticks).
#[must_use]
pub fn contains_subshell_pattern(text: &str) -> bool {
    text.contains("$(") || text.contains('`')
}

/// Extract the binary head from each pipeline segment in a token list.
///
/// Skips leading environment assignments (`VAR=val`) and treats any shell
/// control operator as a segment boundary.
#[must_use]
pub fn command_heads(words: &[String]) -> Vec<String> {
    let mut heads = Vec::new();
    let mut expect_head = true;
    for word in words {
        if is_shell_control_op(word) {
            expect_head = true;
            continue;
        }
        if expect_head && is_env_assignment(word) {
            continue;
        }
        if expect_head {
            heads.push(normalized_binary_name(word));
            expect_head = false;
        }
    }
    heads
}

/// Filter out shell control operators and environment assignments.
#[must_use]
pub fn significant_words(words: &[String]) -> Vec<&str> {
    words
        .iter()
        .filter(|word| !is_shell_control_op(word) && !is_env_assignment(word))
        .map(String::as_str)
        .collect()
}

/// Extract tokens that look like file paths (contain `/`, start with `~` or `.`).
#[must_use]
pub fn path_like_words(words: &[String]) -> Vec<&str> {
    words
        .iter()
        .filter(|word| {
            !is_shell_control_op(word.as_str())
                && !is_env_assignment(word)
                && !word.starts_with('-')
                && (word.contains('/') || word.starts_with('~') || word.starts_with('.'))
        })
        .map(String::as_str)
        .collect()
}

pub(crate) fn significant_word_indices(words: &[String]) -> Vec<usize> {
    words
        .iter()
        .enumerate()
        .filter_map(|(index, word)| {
            (!is_shell_control_op(word) && !is_env_assignment(word)).then_some(index)
        })
        .collect()
}
