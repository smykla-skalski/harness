/// A gated question with fixed options presented to the user.
pub struct Gate {
    pub question: &'static str,
    pub options: &'static [&'static str],
}

impl Gate {
    /// Returns `true` when `question` and `labels` match this gate exactly.
    #[must_use]
    pub fn matches(&self, question: &str, labels: &[impl AsRef<str>]) -> bool {
        question == self.question
            && labels.len() == self.options.len()
            && labels
                .iter()
                .zip(self.options)
                .all(|(actual, expected)| actual.as_ref() == *expected)
    }
}
