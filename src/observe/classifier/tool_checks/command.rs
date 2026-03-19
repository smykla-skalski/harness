use std::path::Path;

use crate::kernel::command_intent::{is_env_assignment, is_shell_control_op, ParsedCommand};

enum ObservedCommandInner {
    Parsed(ParsedCommand),
    Fallback {
        words: Vec<String>,
        significant_word_indices: Vec<usize>,
    },
}

pub(super) struct ObservedCommand<'a> {
    raw: &'a str,
    lower: String,
    inner: ObservedCommandInner,
}

impl<'a> ObservedCommand<'a> {
    pub(super) fn parse(command: &'a str) -> Self {
        if let Ok(parsed) = ParsedCommand::parse(command) {
            return Self {
                raw: command,
                lower: command.to_lowercase(),
                inner: ObservedCommandInner::Parsed(parsed),
            };
        }

        let words = command
            .split_whitespace()
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        let significant_word_indices = words
            .iter()
            .enumerate()
            .filter_map(|(index, word)| {
                (!is_shell_control_op(word) && !is_env_assignment(word))
                    .then_some(index)
            })
            .collect();
        Self {
            raw: command,
            lower: command.to_lowercase(),
            inner: ObservedCommandInner::Fallback {
                words,
                significant_word_indices,
            },
        }
    }

    pub(super) fn raw(&self) -> &str {
        self.raw
    }

    pub(super) fn lower(&self) -> &str {
        &self.lower
    }

    pub(super) fn words(&self) -> &[String] {
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

    pub(super) fn is_harness_command(&self) -> bool {
        match &self.inner {
            ObservedCommandInner::Parsed(parsed) => parsed.first_harness_invocation().is_some(),
            ObservedCommandInner::Fallback { .. } => self.harness_spans().next().is_some(),
        }
    }

    pub(super) fn has_harness_subcommand(&self, subcommand: &str) -> bool {
        match &self.inner {
            ObservedCommandInner::Parsed(parsed) => parsed
                .harness_invocations()
                .any(|invocation| invocation.subcommand() == Some(subcommand)),
            ObservedCommandInner::Fallback { .. } => self
                .harness_spans()
                .any(|span| span.first().is_some_and(|word| *word == subcommand)),
        }
    }

    pub(super) fn harness_has_flag(&self, flag: &str) -> bool {
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

    pub(super) fn manifest_paths(&self) -> Vec<&str> {
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

    pub(super) fn kubectl_query_target(&self) -> Option<String> {
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

    pub(super) fn has_env_prefix_assignment(&self) -> bool {
        self.words()
            .first()
            .is_some_and(|word| is_env_assignment(word))
    }

    pub(super) fn starts_with_export(&self) -> bool {
        self.words().first().is_some_and(|word| word == "export")
    }

    pub(super) fn starts_with_sleep(&self) -> bool {
        self.words().first().is_some_and(|word| word == "sleep")
    }

    pub(super) fn has_harness_after_chain(&self) -> bool {
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

    pub(super) fn harness_spans(&self) -> impl Iterator<Item = Vec<&str>> {
        if let ObservedCommandInner::Parsed(parsed) = &self.inner {
            let spans = parsed
                .harness_invocations()
                .map(crate::kernel::command_intent::HarnessCommandInvocationRef::semantic_words)
                .collect::<Vec<_>>();
            return spans.into_iter();
        }

        let mut spans = Vec::new();
        let words = self.words();
        let significant_word_indices = self.significant_word_indices();
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
            let mut span: Vec<&str> = significant_word_indices[index + 1..search_end]
                .iter()
                .map(|&span_index| words[span_index].as_str())
                .collect();
            if matches!(span.first(), Some(&"run" | &"setup" | &"authoring")) && span.len() > 1 {
                span.remove(0);
            }
            spans.push(span);
        }
        spans.into_iter()
    }
}

/// Flags that tell the parser to consume the next token as a value (not a positional arg).
const KUBECTL_FLAGS_WITH_VALUE: [&str; 7] = [
    "-o",
    "-n",
    "--namespace",
    "--output",
    "-l",
    "--selector",
    "--field-selector",
];

/// Collect up to 2 positional arguments from kubectl tokens following a verb.
///
/// Skips flag tokens and their values, stops at shell control operators or once
/// two positional args have been gathered.
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
        if token.starts_with('-') {
            skip_next = KUBECTL_FLAGS_WITH_VALUE.contains(&token.as_str());
            continue;
        }
        positional.push(token.as_str());
        if positional.len() >= 2 {
            break;
        }
    }
    positional
}
