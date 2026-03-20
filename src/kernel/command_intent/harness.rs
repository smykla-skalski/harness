use std::path::Path;

use super::shell::normalized_binary_name;

#[derive(Debug, Clone, PartialEq, Eq)]
enum FlagValueLocation {
    NextToken(usize),
    Inline {
        token_index: usize,
        value_start: usize,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HarnessCommandInvocation {
    pub(crate) head_index: usize,
    pub(crate) span_indices: Vec<usize>,
    pub(crate) group_index: Option<usize>,
    pub(crate) namespace_index: Option<usize>,
    pub(crate) subcommand_index: Option<usize>,
    gid: Option<FlagValueLocation>,
    pub has_explicit_run_scope: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct HarnessCommandInvocationRef<'a> {
    words: &'a [String],
    invocation: &'a HarnessCommandInvocation,
}

impl<'a> HarnessCommandInvocationRef<'a> {
    pub(crate) const fn new(words: &'a [String], invocation: &'a HarnessCommandInvocation) -> Self {
        Self { words, invocation }
    }

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

pub(crate) fn parse_harness_invocations(
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
