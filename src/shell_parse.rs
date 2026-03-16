use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessCommandInvocation {
    pub head: String,
    pub subcommand: Option<String>,
    pub gid: Option<String>,
    pub has_explicit_run_scope: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedCommand {
    raw: String,
    words: Vec<String>,
    significant_words: Vec<String>,
    heads: Vec<String>,
    harness_invocations: Vec<HarnessCommandInvocation>,
}

impl ParsedCommand {
    /// Parse a shell command into reusable tokenized views.
    ///
    /// # Errors
    /// Returns the shell tokenization error when parsing fails.
    pub fn parse(text: &str) -> Result<Self, shell_words::ParseError> {
        let words = shell_words::split(text)?;
        let significant_words = significant_words(&words);
        let heads = command_heads(&words);
        let harness_invocations = parse_harness_invocations(&significant_words);
        Ok(Self {
            raw: text.to_string(),
            words,
            significant_words,
            heads,
            harness_invocations,
        })
    }

    #[must_use]
    pub fn raw(&self) -> &str {
        &self.raw
    }

    #[must_use]
    pub fn words(&self) -> &[String] {
        &self.words
    }

    #[must_use]
    pub fn significant_words(&self) -> &[String] {
        &self.significant_words
    }

    #[must_use]
    pub fn heads(&self) -> &[String] {
        &self.heads
    }

    #[must_use]
    pub fn first_harness_invocation(&self) -> Option<&HarnessCommandInvocation> {
        self.harness_invocations.first()
    }

    #[must_use]
    pub fn harness_invocations(&self) -> &[HarnessCommandInvocation] {
        &self.harness_invocations
    }
}

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
            .all(|c| c.is_ascii_alphanumeric() || c == '_')
            && prefix
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
    } else {
        false
    }
}

/// Normalize a binary name: strip path prefix, `$` / `${...}` wrappers, and lowercase.
#[must_use]
pub fn normalized_binary_name(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    if let Some(inner) = s.strip_prefix("${").and_then(|rest| rest.strip_suffix('}')) {
        s = inner.to_string();
    } else if let Some(stripped) = s.strip_prefix('$') {
        s = stripped.to_string();
    }
    Path::new(&s)
        .file_name()
        .map_or_else(|| s.to_lowercase(), |n| n.to_string_lossy().to_lowercase())
}

/// Extract the binary head from each pipeline segment in a token list.
///
/// Skips leading environment assignments (`VAR=val`) and treats any shell
/// control operator as a segment boundary.
#[must_use]
pub fn command_heads(words: &[String]) -> Vec<String> {
    let mut heads = Vec::new();
    let mut expect = true;
    for word in words {
        if is_shell_control_op(word) {
            expect = true;
            continue;
        }
        if expect && is_env_assignment(word) {
            continue;
        }
        if expect {
            heads.push(normalized_binary_name(word));
            expect = false;
        }
    }
    heads
}

/// Filter out shell control operators and environment assignments.
#[must_use]
pub fn significant_words(words: &[String]) -> Vec<String> {
    words
        .iter()
        .filter(|w| !is_shell_control_op(w) && !is_env_assignment(w))
        .cloned()
        .collect()
}

/// Extract tokens that look like file paths (contain `/`, start with `~` or `.`).
#[must_use]
pub fn path_like_words(words: &[String]) -> Vec<&str> {
    words
        .iter()
        .filter(|w| {
            !is_shell_control_op(w.as_str())
                && !is_env_assignment(w)
                && !w.starts_with('-')
                && (w.contains('/') || w.starts_with('~') || w.starts_with('.'))
        })
        .map(String::as_str)
        .collect()
}

#[must_use]
pub fn extract_flag_value(words: &[String], flag: &str) -> Option<String> {
    for (index, word) in words.iter().enumerate() {
        if word == flag {
            return words.get(index + 1).cloned();
        }
        if let Some(value) = word.strip_prefix(&format!("{flag}=")) {
            return Some(value.to_string());
        }
    }
    None
}

fn parse_harness_invocations(significant_words: &[String]) -> Vec<HarnessCommandInvocation> {
    let mut invocations = Vec::new();
    let len = significant_words.len();
    for (index, word) in significant_words.iter().enumerate() {
        let head = Path::new(word)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(word.as_str());
        if head != "harness" {
            continue;
        }
        let subcommand = significant_words
            .get(index + 1)
            .filter(|next| !next.starts_with('-'))
            .cloned();
        let search_end = significant_words[index + 1..]
            .iter()
            .position(|candidate| {
                Path::new(candidate)
                    .file_name()
                    .and_then(|name| name.to_str())
                    == Some("harness")
            })
            .map_or(len, |offset| index + 1 + offset);
        let span = &significant_words[index + 1..search_end];
        let gid = extract_flag_value(span, "--gid");
        let has_explicit_run_scope = span.iter().any(|word| {
            matches!(word.as_str(), "--run-dir" | "--run-id" | "--run-root")
                || word.starts_with("--run-dir=")
                || word.starts_with("--run-id=")
                || word.starts_with("--run-root=")
        });
        invocations.push(HarnessCommandInvocation {
            head: word.clone(),
            subcommand,
            gid,
            has_explicit_run_scope,
        });
    }
    invocations
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_heads_basic() {
        let words: Vec<String> = vec!["kubectl", "get", "pods"]
            .into_iter()
            .map(String::from)
            .collect();
        assert_eq!(command_heads(&words), vec!["kubectl"]);
    }

    #[test]
    fn command_heads_with_pipe() {
        let words: Vec<String> = vec!["echo", "hello", "|", "grep", "hello"]
            .into_iter()
            .map(String::from)
            .collect();
        assert_eq!(command_heads(&words), vec!["echo", "grep"]);
    }

    #[test]
    fn command_heads_with_env_var() {
        let words: Vec<String> = vec!["FOO=bar", "kubectl", "get", "pods"]
            .into_iter()
            .map(String::from)
            .collect();
        assert_eq!(command_heads(&words), vec!["kubectl"]);
    }

    #[test]
    fn normalized_binary_name_strips_path() {
        assert_eq!(normalized_binary_name("/usr/bin/kubectl"), "kubectl");
    }

    #[test]
    fn normalized_binary_name_strips_dollar() {
        assert_eq!(normalized_binary_name("$KUMACTL"), "kumactl");
        assert_eq!(normalized_binary_name("${KUMACTL}"), "kumactl");
    }

    #[test]
    fn is_env_assignment_positive() {
        assert!(is_env_assignment("FOO=bar"));
        assert!(is_env_assignment("PATH=/usr/bin"));
    }

    #[test]
    fn is_env_assignment_negative() {
        assert!(!is_env_assignment("kubectl"));
        assert!(!is_env_assignment("=value"));
    }

    #[test]
    fn parsed_command_extracts_harness_invocation() {
        let parsed =
            ParsedCommand::parse("KUBECONFIG=/tmp/conf harness report group --gid g01").unwrap();
        assert_eq!(parsed.heads(), ["harness"]);
        assert_eq!(parsed.harness_invocations().len(), 1);
        let invocation = parsed.first_harness_invocation().unwrap();
        assert_eq!(invocation.subcommand.as_deref(), Some("report"));
        assert_eq!(invocation.gid.as_deref(), Some("g01"));
    }
}
