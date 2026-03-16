use std::path::Path;

use crate::shell_parse::{self, ParsedCommand, is_env_assignment};

pub(super) struct ObservedCommand {
    pub(super) raw: String,
    pub(super) lower: String,
    pub(super) words: Vec<String>,
    significant_words: Vec<String>,
}

impl ObservedCommand {
    pub(super) fn parse(command: &str) -> Self {
        if let Ok(parsed) = ParsedCommand::parse(command) {
            return Self::from_parsed(&parsed);
        }

        let words = command
            .split_whitespace()
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        let significant_words = shell_parse::significant_words(&words);
        Self {
            raw: command.to_string(),
            lower: command.to_lowercase(),
            words,
            significant_words,
        }
    }

    fn from_parsed(parsed: &ParsedCommand) -> Self {
        Self {
            raw: parsed.raw().to_string(),
            lower: parsed.raw().to_lowercase(),
            words: parsed.words().to_vec(),
            significant_words: parsed.significant_words().to_vec(),
        }
    }

    pub(super) fn is_harness_command(&self) -> bool {
        self.harness_spans().next().is_some()
    }

    pub(super) fn has_harness_subcommand(&self, subcommand: &str) -> bool {
        self.harness_spans()
            .any(|span| span.first().is_some_and(|word| word == subcommand))
    }

    pub(super) fn harness_has_flag(&self, flag: &str) -> bool {
        self.harness_spans().any(|span| {
            span.iter()
                .any(|word| word == flag || word.starts_with(&format!("{flag}=")))
        })
    }

    pub(super) fn manifest_paths(&self) -> Vec<String> {
        let mut manifests = Vec::new();
        for span in self.harness_spans() {
            let mut index = 0;
            while index < span.len() {
                if span[index] == "--manifest" {
                    if let Some(path) = span.get(index + 1) {
                        manifests.push(path.clone());
                    }
                    index += 2;
                    continue;
                }
                if let Some(value) = span[index].strip_prefix("--manifest=") {
                    manifests.push(value.to_string());
                }
                index += 1;
            }
        }
        manifests
    }

    pub(super) fn kubectl_query_target(&self) -> Option<String> {
        let kubectl_position = self.words.iter().position(|word| {
            Path::new(word)
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|head| head == "kubectl")
        })?;
        let remaining = &self.words[kubectl_position + 1..];
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
        self.words
            .first()
            .is_some_and(|word| is_env_assignment(word))
    }

    pub(super) fn starts_with_export(&self) -> bool {
        self.words.first().is_some_and(|word| word == "export")
    }

    pub(super) fn starts_with_sleep(&self) -> bool {
        self.words.first().is_some_and(|word| word == "sleep")
    }

    pub(super) fn has_harness_after_chain(&self) -> bool {
        let mut seen_chain = false;
        let mut expect_head = true;
        for word in &self.words {
            if shell_parse::is_shell_control_op(word) {
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

    pub(super) fn harness_spans(&self) -> impl Iterator<Item = &[String]> {
        let mut spans = Vec::new();
        let len = self.significant_words.len();
        for (index, word) in self.significant_words.iter().enumerate() {
            let head = Path::new(word)
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or(word.as_str());
            if head != "harness" {
                continue;
            }
            let search_end = self.significant_words[index + 1..]
                .iter()
                .position(|candidate| {
                    Path::new(candidate)
                        .file_name()
                        .and_then(|name| name.to_str())
                        == Some("harness")
                })
                .map_or(len, |offset| index + 1 + offset);
            spans.push(&self.significant_words[index + 1..search_end]);
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
fn collect_kubectl_positional_args(tokens: &[String]) -> Vec<String> {
    let mut positional = Vec::new();
    let mut skip_next = false;
    for token in tokens {
        if skip_next {
            skip_next = false;
            continue;
        }
        if shell_parse::is_shell_control_op(token) {
            break;
        }
        if token.starts_with('-') {
            skip_next = KUBECTL_FLAGS_WITH_VALUE.contains(&token.as_str());
            continue;
        }
        positional.push(token.clone());
        if positional.len() >= 2 {
            break;
        }
    }
    positional
}
