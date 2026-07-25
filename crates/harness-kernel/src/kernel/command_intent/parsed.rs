use super::harness::{
    HarnessCommandInvocation, HarnessCommandInvocationRef, parse_harness_invocations,
};
use super::shell::{command_heads, significant_word_indices};

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
            .map(|invocation| HarnessCommandInvocationRef::new(&self.words, invocation))
    }

    pub fn harness_invocations(&self) -> impl Iterator<Item = HarnessCommandInvocationRef<'_>> {
        self.harness_invocations
            .iter()
            .map(|invocation| HarnessCommandInvocationRef::new(&self.words, invocation))
    }

    #[must_use]
    pub(crate) fn significant_word_indices(&self) -> &[usize] {
        &self.significant_word_indices
    }
}
