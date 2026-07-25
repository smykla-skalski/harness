use std::path::Path;

use super::fallback::{collect_kubectl_positional_args, fallback_harness_spans};
use super::parsed::ParsedCommand;
use super::shell::{is_env_assignment, is_shell_control_op};

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
        let significant_word_indices = super::shell::significant_word_indices(&words);
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
                tokenization_error, ..
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
                .map(super::harness::HarnessCommandInvocationRef::semantic_words)
                .collect::<Vec<_>>();
            return spans.into_iter();
        }

        fallback_harness_spans(self.words(), self.significant_word_indices()).into_iter()
    }
}
