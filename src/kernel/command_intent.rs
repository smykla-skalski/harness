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
    span_indices: Vec<usize>,
    group_index: Option<usize>,
    namespace_index: Option<usize>,
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
    pub fn group(self) -> Option<&'a str> {
        self.invocation
            .group_index
            .map(|index| self.words[index].as_str())
    }

    #[must_use]
    pub fn command_label(self) -> String {
        let mut parts = vec![self.head()];
        if let Some(group) = self.group() {
            parts.push(group);
        }
        if let Some(namespace) = self
            .invocation
            .namespace_index
            .map(|index| self.words[index].as_str())
        {
            parts.push(namespace);
        }
        if let Some(subcommand) = self.subcommand()
            && Some(subcommand) != self.group()
        {
            parts.push(subcommand);
        }
        parts.join(" ")
    }

    #[must_use]
    pub fn span_words(self) -> Vec<&'a str> {
        self.invocation
            .span_indices
            .iter()
            .map(|&index| self.words[index].as_str())
            .collect()
    }

    #[must_use]
    pub fn semantic_words(self) -> Vec<&'a str> {
        let mut words = self.span_words();
        if matches!(words.first(), Some(&"run" | &"setup" | &"authoring")) && words.len() > 1 {
            words.remove(0);
        }
        if matches!(words.first(), Some(&"kuma")) && words.len() > 1 {
            words.remove(0);
        }
        words
    }

    #[must_use]
    pub fn has_flag(self, flag: &str) -> bool {
        self.span_words().into_iter().any(|word| {
            word == flag
                || word
                    .strip_prefix(flag)
                    .is_some_and(|rest| rest.starts_with('='))
        })
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

#[derive(Debug, Clone, PartialEq, Eq)]
enum ObservedCommandInner {
    Parsed(ParsedCommand),
    Fallback {
        words: Vec<String>,
        significant_word_indices: Vec<usize>,
        tokenization_error: String,
    },
}

/// Shared command facts for hook guards and observe classification.
///
/// This type prefers the fully tokenized `ParsedCommand` shape but preserves a
/// lossy fallback when shell tokenization fails so read-only analysis can keep
/// working while hook enforcement still reports malformed commands explicitly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObservedCommand {
    raw: String,
    lower: String,
    inner: ObservedCommandInner,
}

impl ObservedCommand {
    #[must_use]
    pub fn parse(command: &str) -> Self {
        if let Ok(parsed) = ParsedCommand::parse(command) {
            return Self {
                raw: command.to_string(),
                lower: command.to_lowercase(),
                inner: ObservedCommandInner::Parsed(parsed),
            };
        }

        let words = command
            .split_whitespace()
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        let significant_word_indices = significant_word_indices(&words);
        let tokenization_error = ParsedCommand::parse(command)
            .err()
            .map_or_else(String::new, |error| error.to_string());
        Self {
            raw: command.to_string(),
            lower: command.to_lowercase(),
            inner: ObservedCommandInner::Fallback {
                words,
                significant_word_indices,
                tokenization_error,
            },
        }
    }

    #[must_use]
    pub fn raw(&self) -> &str {
        &self.raw
    }

    #[must_use]
    pub fn lower(&self) -> &str {
        &self.lower
    }

    #[must_use]
    pub fn parsed(&self) -> Option<&ParsedCommand> {
        match &self.inner {
            ObservedCommandInner::Parsed(parsed) => Some(parsed),
            ObservedCommandInner::Fallback { .. } => None,
        }
    }

    #[must_use]
    pub fn tokenization_error(&self) -> Option<&str> {
        match &self.inner {
            ObservedCommandInner::Parsed(_) => None,
            ObservedCommandInner::Fallback {
                tokenization_error,
                ..
            } => Some(tokenization_error.as_str()),
        }
    }

    #[must_use]
    pub fn words(&self) -> &[String] {
        match &self.inner {
            ObservedCommandInner::Parsed(parsed) => parsed.words(),
            ObservedCommandInner::Fallback { words, .. } => words,
        }
    }

    fn significant_word_indices(&self) -> &[usize] {
        match &self.inner {
            ObservedCommandInner::Parsed(parsed) => parsed.significant_word_indices(),
            ObservedCommandInner::Fallback {
                significant_word_indices,
                ..
            } => significant_word_indices,
        }
    }

    #[must_use]
    pub fn is_harness_command(&self) -> bool {
        match &self.inner {
            ObservedCommandInner::Parsed(parsed) => parsed.first_harness_invocation().is_some(),
            ObservedCommandInner::Fallback { .. } => self.harness_spans().next().is_some(),
        }
    }

    #[must_use]
    pub fn has_harness_subcommand(&self, subcommand: &str) -> bool {
        match &self.inner {
            ObservedCommandInner::Parsed(parsed) => parsed
                .harness_invocations()
                .any(|invocation| invocation.subcommand() == Some(subcommand)),
            ObservedCommandInner::Fallback { .. } => self
                .harness_spans()
                .any(|span| span.first().is_some_and(|word| *word == subcommand)),
        }
    }

    #[must_use]
    pub fn harness_has_flag(&self, flag: &str) -> bool {
        match &self.inner {
            ObservedCommandInner::Parsed(parsed) => parsed
                .harness_invocations()
                .any(|invocation| invocation.has_flag(flag)),
            ObservedCommandInner::Fallback { .. } => self.harness_spans().any(|span| {
                span.iter().any(|word| {
                    *word == flag
                        || word
                            .strip_prefix(flag)
                            .is_some_and(|rest| rest.starts_with('='))
                })
            }),
        }
    }

    #[must_use]
    pub fn manifest_paths(&self) -> Vec<&str> {
        let mut manifests = Vec::new();
        for span in self.harness_spans() {
            let mut index = 0;
            while index < span.len() {
                if span[index] == "--manifest" {
                    if let Some(path) = span.get(index + 1) {
                        manifests.push(*path);
                    }
                    index += 2;
                    continue;
                }
                if let Some(value) = span[index].strip_prefix("--manifest=") {
                    manifests.push(value);
                }
                index += 1;
            }
        }
        manifests
    }

    #[must_use]
    pub fn kubectl_query_target(&self) -> Option<String> {
        let kubectl_position = self.words().iter().position(|word| {
            Path::new(word)
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|head| head == "kubectl")
        })?;
        let remaining = &self.words()[kubectl_position + 1..];
        let (verb_index, verb) = remaining.iter().enumerate().find_map(|(index, token)| {
            if matches!(token.as_str(), "get" | "describe") {
                Some((index, token.as_str()))
            } else {
                None
            }
        })?;
        let after_verb = &remaining[verb_index + 1..];
        let positional = collect_kubectl_positional_args(after_verb);

        if positional.is_empty() {
            return None;
        }

        Some(format!("{verb} {}", positional.join(" ")))
    }

    #[must_use]
    pub fn has_env_prefix_assignment(&self) -> bool {
        self.words()
            .first()
            .is_some_and(|word| is_env_assignment(word))
    }

    #[must_use]
    pub fn starts_with_export(&self) -> bool {
        self.words().first().is_some_and(|word| word == "export")
    }

    #[must_use]
    pub fn starts_with_sleep(&self) -> bool {
        self.words().first().is_some_and(|word| word == "sleep")
    }

    #[must_use]
    pub fn has_harness_after_chain(&self) -> bool {
        if let ObservedCommandInner::Parsed(parsed) = &self.inner {
            return parsed.heads().iter().skip(1).any(|head| head == "harness");
        }
        let mut seen_chain = false;
        let mut expect_head = true;
        for word in self.words() {
            if is_shell_control_op(word) {
                seen_chain = true;
                expect_head = true;
                continue;
            }
            if expect_head && is_env_assignment(word) {
                continue;
            }
            if expect_head {
                if seen_chain
                    && Path::new(word)
                        .file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|head| head == "harness")
                {
                    return true;
                }
                expect_head = false;
            }
        }
        false
    }

    pub fn harness_spans(&self) -> impl Iterator<Item = Vec<&str>> {
        if let ObservedCommandInner::Parsed(parsed) = &self.inner {
            let spans = parsed
                .harness_invocations()
                .map(HarnessCommandInvocationRef::semantic_words)
                .collect::<Vec<_>>();
            return spans.into_iter();
        }

        fallback_harness_spans(self.words(), self.significant_word_indices()).into_iter()
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

/// Strip subshell and backtick wrappers from a token.
///
/// Handles `$(cmd)`, nested `$($(cmd))`, split tokens like `$(kubectl`
/// and `kuma-system)`, and backtick wrappers.
fn strip_shell_wrappers(raw: &str) -> String {
    let mut s = raw.trim().to_string();

    // Strip subshell substitution: $(cmd) -> cmd
    // Loop handles nested: $($(cmd)) -> $(cmd) -> cmd
    loop {
        if let Some(inner) = s.strip_prefix("$(").and_then(|rest| rest.strip_suffix(')')) {
            s = inner.to_string();
            continue;
        }
        if let Some(inner) = s.strip_prefix("$(") {
            s = inner.to_string();
            continue;
        }
        if s.ends_with(')') && !s.contains('(') {
            s = s[..s.len() - 1].to_string();
        }
        break;
    }

    // Strip backtick wrappers
    if s.starts_with('`') {
        s = s.trim_start_matches('`').to_string();
    }
    if s.ends_with('`') {
        s = s.trim_end_matches('`').to_string();
    }

    s
}

/// Normalize a binary name: strip path prefix, `$` / `${...}` wrappers,
/// `$(...)` subshell wrappers, backtick wrappers, and lowercase.
#[must_use]
pub fn normalized_binary_name(raw: &str) -> String {
    let mut s = strip_shell_wrappers(raw);

    // Strip ${VAR} and $VAR
    if let Some(inner) = s.strip_prefix("${").and_then(|rest| rest.strip_suffix('}')) {
        s = inner.to_string();
    } else if let Some(stripped) = s.strip_prefix('$') {
        s = stripped.to_string();
    }

    Path::new(&s)
        .file_name()
        .map_or_else(|| s.to_lowercase(), |n| n.to_string_lossy().to_lowercase())
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

fn is_harness_scope_group(word: &str) -> bool {
    matches!(word, "run" | "setup" | "authoring")
}

fn is_harness_namespace(word: &str) -> bool {
    matches!(word, "kuma")
}

/// Return the semantic harness command tail starting at the effective command.
///
/// For grouped invocations like `harness run apply` or namespaced invocations
/// like `harness run kuma token`, this strips the grouping and namespace
/// tokens and returns the effective command tail. Flat invocations are returned
/// unchanged.
#[must_use]
pub fn semantic_harness_tail<'a>(significant_words: &'a [&'a str]) -> Option<&'a [&'a str]> {
    let (head, rest) = significant_words.split_first()?;
    if normalized_binary_name(head) != "harness" {
        return None;
    }
    let Some(first) = rest.first().copied() else {
        return Some(rest);
    };
    if is_harness_scope_group(first)
        && let Some(offset) = rest[1..].iter().position(|word| !word.starts_with('-'))
    {
        let mut tail = &rest[offset + 1..];
        if let Some(namespace) = tail.first().copied()
            && is_harness_namespace(namespace)
            && let Some(namespace_offset) = tail[1..].iter().position(|word| !word.starts_with('-'))
        {
            tail = &tail[namespace_offset + 1..];
        }
        return Some(tail);
    }
    Some(rest)
}

/// Return the effective harness subcommand for flat and grouped invocations.
#[must_use]
pub fn semantic_harness_subcommand<'a>(significant_words: &'a [&'a str]) -> Option<&'a str> {
    semantic_harness_tail(significant_words)?
        .iter()
        .copied()
        .find(|word| !word.starts_with('-'))
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
        let group_index = span
            .iter()
            .copied()
            .find(|&span_index| !words[span_index].starts_with('-'))
            .filter(|&span_index| is_harness_scope_group(&words[span_index]));
        let namespace_index = if let Some(group_index) = group_index {
            span.iter()
                .copied()
                .skip_while(|&span_index| span_index != group_index)
                .skip(1)
                .find(|&span_index| {
                    !words[span_index].starts_with('-') && is_harness_namespace(&words[span_index])
                })
        } else {
            None
        };
        let subcommand_index = if let Some(namespace_index) = namespace_index {
            span.iter()
                .copied()
                .skip_while(|&span_index| span_index != namespace_index)
                .skip(1)
                .find(|&span_index| !words[span_index].starts_with('-'))
                .or(Some(namespace_index))
        } else if let Some(group_index) = group_index {
            span.iter()
                .copied()
                .skip_while(|&span_index| span_index != group_index)
                .skip(1)
                .find(|&span_index| !words[span_index].starts_with('-'))
                .or(Some(group_index))
        } else {
            span.iter()
                .copied()
                .find(|&span_index| !words[span_index].starts_with('-'))
        };
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
            span_indices: span.to_vec(),
            group_index,
            namespace_index,
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

/// Flags that tell kubectl to consume the next token as a value rather than a
/// positional resource argument.
const KUBECTL_FLAGS_WITH_VALUE: [&str; 7] = [
    "-o",
    "-n",
    "--namespace",
    "--output",
    "-l",
    "--selector",
    "--field-selector",
];

fn collect_kubectl_positional_args(tokens: &[String]) -> Vec<&str> {
    let mut positional = Vec::new();
    let mut skip_next = false;

    for token in tokens {
        if skip_next {
            skip_next = false;
            continue;
        }
        if is_shell_control_op(token) {
            break;
        }
        if KUBECTL_FLAGS_WITH_VALUE.contains(&token.as_str()) {
            skip_next = true;
            continue;
        }
        if token.starts_with('-') {
            continue;
        }
        positional.push(token.as_str());
        if positional.len() == 2 {
            break;
        }
    }

    positional
}

fn fallback_harness_spans<'a>(
    words: &'a [String],
    significant_word_indices: &[usize],
) -> Vec<Vec<&'a str>> {
    let mut spans = Vec::new();
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
        let search_end = next_harness_index(words, significant_word_indices, index).unwrap_or(len);
        let span = semantic_fallback_span(words, &significant_word_indices[index + 1..search_end]);
        spans.push(span);
    }
    spans
}

fn next_harness_index(
    words: &[String],
    significant_word_indices: &[usize],
    start_index: usize,
) -> Option<usize> {
    significant_word_indices[start_index + 1..]
        .iter()
        .position(|&candidate_index| {
            Path::new(&words[candidate_index])
                .file_name()
                .and_then(|name| name.to_str())
                == Some("harness")
        })
        .map(|offset| start_index + 1 + offset)
}

fn semantic_fallback_span<'a>(words: &'a [String], span_indices: &[usize]) -> Vec<&'a str> {
    let mut span: Vec<&str> = span_indices
        .iter()
        .map(|&span_index| words[span_index].as_str())
        .collect();
    if matches!(span.first(), Some(&"run" | &"setup" | &"authoring")) && span.len() > 1 {
        span.remove(0);
    }
    if matches!(span.first(), Some(&"kuma")) && span.len() > 1 {
        span.remove(0);
    }
    span
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

    #[test]
    fn parsed_command_extracts_grouped_harness_invocation() {
        let parsed =
            ParsedCommand::parse("KUBECONFIG=/tmp/conf harness run report group --gid g01")
                .unwrap();
        let invocation = parsed.first_harness_invocation().unwrap();
        assert_eq!(invocation.group(), Some("run"));
        assert_eq!(invocation.subcommand(), Some("report"));
        assert_eq!(invocation.command_label(), "harness run report");
        assert_eq!(invocation.gid(), Some("g01"));
    }

    #[test]
    fn parsed_command_extracts_namespaced_harness_invocation() {
        let parsed =
            ParsedCommand::parse("harness run kuma token dataplane --name demo --mesh default")
                .unwrap();
        let invocation = parsed.first_harness_invocation().unwrap();
        assert_eq!(invocation.group(), Some("run"));
        assert_eq!(invocation.subcommand(), Some("token"));
        assert_eq!(invocation.command_label(), "harness run kuma token");
    }

    #[test]
    fn semantic_harness_tail_strips_group_prefix() {
        let grouped = ["harness", "setup", "cluster", "single-up"];
        assert_eq!(
            semantic_harness_tail(&grouped).unwrap(),
            ["cluster", "single-up"]
        );
        let namespaced = ["harness", "run", "kuma", "token", "dataplane"];
        assert_eq!(
            semantic_harness_tail(&namespaced).unwrap(),
            ["token", "dataplane"]
        );
        let flat = ["harness", "report", "group"];
        assert_eq!(semantic_harness_tail(&flat).unwrap(), ["report", "group"]);
    }

    #[test]
    fn normalized_binary_name_strips_dollar_paren() {
        assert_eq!(normalized_binary_name("$(kubectl"), "kubectl");
        assert_eq!(normalized_binary_name("$(kubectl)"), "kubectl");
    }

    #[test]
    fn normalized_binary_name_strips_backticks() {
        assert_eq!(normalized_binary_name("`kumactl`"), "kumactl");
        assert_eq!(normalized_binary_name("`kumactl"), "kumactl");
    }

    #[test]
    fn normalized_binary_name_strips_nested_subshell() {
        assert_eq!(normalized_binary_name("$($(kubectl)"), "kubectl");
    }
}
