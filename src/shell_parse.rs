use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
enum FlagValueLocation {
    NextToken(usize),
    Inline {
        token_index: usize,
        value_start: usize,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessCommandInvocation {
    head_index: usize,
    subcommand_index: Option<usize>,
    gid: Option<FlagValueLocation>,
    pub has_explicit_run_scope: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct HarnessCommandInvocationRef<'a> {
    words: &'a [String],
    invocation: &'a HarnessCommandInvocation,
}

impl<'a> HarnessCommandInvocationRef<'a> {
    #[must_use]
    pub fn head(self) -> &'a str {
        self.words[self.invocation.head_index].as_str()
    }

    #[must_use]
    pub fn subcommand(self) -> Option<&'a str> {
        self.invocation
            .subcommand_index
            .map(|index| self.words[index].as_str())
    }

    #[must_use]
    pub fn gid(self) -> Option<&'a str> {
        match self.invocation.gid {
            Some(FlagValueLocation::NextToken(index)) => Some(self.words[index].as_str()),
            Some(FlagValueLocation::Inline {
                token_index,
                value_start,
            }) => Some(&self.words[token_index][value_start..]),
            None => None,
        }
    }

    #[must_use]
    pub const fn has_explicit_run_scope(self) -> bool {
        self.invocation.has_explicit_run_scope
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedCommand {
    words: Vec<String>,
    significant_word_indices: Vec<usize>,
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
        let significant_word_indices = significant_word_indices(&words);
        let heads = command_heads(&words);
        let harness_invocations = parse_harness_invocations(&words, &significant_word_indices);
        Ok(Self {
            words,
            significant_word_indices,
            heads,
            harness_invocations,
        })
    }

    #[must_use]
    pub fn words(&self) -> &[String] {
        &self.words
    }

    pub fn significant_words(&self) -> impl Iterator<Item = &str> {
        self.significant_word_indices
            .iter()
            .map(|&index| self.words[index].as_str())
    }

    #[must_use]
    pub fn heads(&self) -> &[String] {
        &self.heads
    }

    #[must_use]
    pub fn first_harness_invocation(&self) -> Option<HarnessCommandInvocationRef<'_>> {
        self.harness_invocations
            .first()
            .map(|invocation| HarnessCommandInvocationRef {
                words: &self.words,
                invocation,
            })
    }

    pub fn harness_invocations(&self) -> impl Iterator<Item = HarnessCommandInvocationRef<'_>> {
        self.harness_invocations
            .iter()
            .map(|invocation| HarnessCommandInvocationRef {
                words: &self.words,
                invocation,
            })
    }

    #[must_use]
    pub(crate) fn significant_word_indices(&self) -> &[usize] {
        &self.significant_word_indices
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
pub fn significant_words(words: &[String]) -> Vec<&str> {
    words
        .iter()
        .filter(|w| !is_shell_control_op(w) && !is_env_assignment(w))
        .map(String::as_str)
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
pub fn extract_flag_value<'a>(words: &'a [String], flag: &str) -> Option<&'a str> {
    for (index, word) in words.iter().enumerate() {
        if word == flag {
            return words.get(index + 1).map(String::as_str);
        }
        if let Some(rest) = word.strip_prefix(flag)
            && let Some(value) = rest.strip_prefix('=')
        {
            return Some(value);
        }
    }
    None
}

fn significant_word_indices(words: &[String]) -> Vec<usize> {
    words
        .iter()
        .enumerate()
        .filter_map(|(index, word)| {
            (!is_shell_control_op(word) && !is_env_assignment(word)).then_some(index)
        })
        .collect()
}

fn parse_harness_invocations(
    words: &[String],
    significant_word_indices: &[usize],
) -> Vec<HarnessCommandInvocation> {
    let mut invocations = Vec::new();
    let len = significant_word_indices.len();
    for (index, &word_index) in significant_word_indices.iter().enumerate() {
        let word = &words[word_index];
        let head = Path::new(word)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(word.as_str());
        if head != "harness" {
            continue;
        }
        let subcommand_index = significant_word_indices
            .get(index + 1)
            .copied()
            .filter(|&next_index| !words[next_index].starts_with('-'));
        let search_end = significant_word_indices[index + 1..]
            .iter()
            .position(|&candidate_index| {
                Path::new(&words[candidate_index])
                    .file_name()
                    .and_then(|name| name.to_str())
                    == Some("harness")
            })
            .map_or(len, |offset| index + 1 + offset);
        let span = &significant_word_indices[index + 1..search_end];
        let gid = extract_flag_value_location(words, span, "--gid");
        let has_explicit_run_scope = span.iter().any(|&span_index| {
            let span_word = &words[span_index];
            matches!(span_word.as_str(), "--run-dir" | "--run-id" | "--run-root")
                || span_word.starts_with("--run-dir=")
                || span_word.starts_with("--run-id=")
                || span_word.starts_with("--run-root=")
        });
        invocations.push(HarnessCommandInvocation {
            head_index: word_index,
            subcommand_index,
            gid,
            has_explicit_run_scope,
        });
    }
    invocations
}

fn extract_flag_value_location(
    words: &[String],
    span_indices: &[usize],
    flag: &str,
) -> Option<FlagValueLocation> {
    for (offset, &span_index) in span_indices.iter().enumerate() {
        let word = &words[span_index];
        if word == flag {
            return span_indices
                .get(offset + 1)
                .copied()
                .map(FlagValueLocation::NextToken);
        }
        if let Some(rest) = word.strip_prefix(flag)
            && rest.starts_with('=')
        {
            return Some(FlagValueLocation::Inline {
                token_index: span_index,
                value_start: flag.len() + 1,
            });
        }
    }
    None
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
        assert_eq!(parsed.harness_invocations().count(), 1);
        let invocation = parsed.first_harness_invocation().unwrap();
        assert_eq!(invocation.head(), "harness");
        assert_eq!(invocation.subcommand(), Some("report"));
        assert_eq!(invocation.gid(), Some("g01"));
    }
}
