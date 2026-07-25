//! Minimal `{{ name }}` prompt templating. No template-engine dependency: a
//! single non-recursive substitution pass over a whitelist of variable names.
//! Values are inserted verbatim and never re-scanned, so an item body that
//! itself contains `{{ x }}` is inert. Single braces (and the braces inside an
//! embedded `JSON` value) pass through untouched -- only a `{{ ... }}` pair
//! whose trimmed contents form a valid identifier is treated as a placeholder.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::mem;

/// One parsed piece of a template: literal text, or a variable reference.
enum Segment {
    Literal(String),
    Variable(String),
}

/// A prompt template. Cheap to clone; holds the raw source text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PromptTemplate {
    raw: String,
}

/// A referenced variable was not available when rendering a concrete item.
/// Surfaced at the spawn preflight so the agent never starts with a prompt it
/// could not fully render.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PromptRenderError {
    pub(crate) variable: String,
}

/// A configured override referenced a variable name that does not exist for
/// its prompt. Caught when the configuration is read, so a typo is known
/// before anything tries to use that prompt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PromptConfigError {
    pub(crate) unknown: Vec<String>,
}

impl fmt::Display for PromptRenderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "prompt variable '{}' is not available for this item",
            self.variable
        )
    }
}

impl fmt::Display for PromptConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "prompt references unknown variables: {}",
            self.unknown.join(", ")
        )
    }
}

impl PromptTemplate {
    #[must_use]
    pub(crate) fn new(raw: impl Into<String>) -> Self {
        Self { raw: raw.into() }
    }

    /// Substitute every `{{ name }}` from `vars`. A referenced name absent from
    /// `vars` is an unavailable variable and fails the whole render.
    pub(crate) fn render(
        &self,
        vars: &BTreeMap<&'static str, String>,
    ) -> Result<String, PromptRenderError> {
        let mut rendered = String::with_capacity(self.raw.len());
        for segment in parse_segments(&self.raw) {
            match segment {
                Segment::Literal(text) => rendered.push_str(&text),
                Segment::Variable(name) => match vars.get(name.as_str()) {
                    Some(value) => rendered.push_str(value),
                    None => return Err(PromptRenderError { variable: name }),
                },
            }
        }
        Ok(rendered)
    }

    /// The distinct valid-identifier variable names this template references.
    #[must_use]
    pub(crate) fn referenced_variables(&self) -> BTreeSet<String> {
        parse_segments(&self.raw)
            .into_iter()
            .filter_map(|segment| match segment {
                Segment::Variable(name) => Some(name),
                Segment::Literal(_) => None,
            })
            .collect()
    }

    /// Reject any referenced name outside `allowed`. Used at catalog load so a
    /// typo fails before any agent starts.
    pub(crate) fn validate_names(&self, allowed: &[&'static str]) -> Result<(), PromptConfigError> {
        let unknown: Vec<String> = self
            .referenced_variables()
            .into_iter()
            .filter(|name| !allowed.contains(&name.as_str()))
            .collect();
        if unknown.is_empty() {
            Ok(())
        } else {
            Err(PromptConfigError { unknown })
        }
    }
}

/// Split `raw` into literal and variable segments. A `{{` with no closing `}}`,
/// or whose trimmed contents are not a valid identifier, stays literal.
fn parse_segments(raw: &str) -> Vec<Segment> {
    let chars: Vec<char> = raw.chars().collect();
    let mut segments = Vec::new();
    let mut literal = String::new();
    let mut index = 0;
    while index < chars.len() {
        if chars[index] == '{' && chars.get(index + 1) == Some(&'{') {
            if let Some((name, resume)) = try_placeholder(&chars, index) {
                if !literal.is_empty() {
                    segments.push(Segment::Literal(mem::take(&mut literal)));
                }
                segments.push(Segment::Variable(name));
                index = resume;
                continue;
            }
            literal.push_str("{{");
            index += 2;
            continue;
        }
        literal.push(chars[index]);
        index += 1;
    }
    if !literal.is_empty() {
        segments.push(Segment::Literal(literal));
    }
    segments
}

/// Given `chars[start..]` beginning with `{{`, return the referenced name and
/// the index just past the closing `}}` when the pair forms a placeholder.
fn try_placeholder(chars: &[char], start: usize) -> Option<(String, usize)> {
    let mut cursor = start + 2;
    while cursor + 1 < chars.len() {
        if chars[cursor] == '}' && chars[cursor + 1] == '}' {
            let inner: String = chars[start + 2..cursor].iter().collect();
            let name = inner.trim();
            return is_identifier(name).then(|| (name.to_string(), cursor + 2));
        }
        cursor += 1;
    }
    None
}

/// A template identifier: an ASCII letter or underscore, then letters, digits,
/// or underscores. Deliberately no dots -- flat names keep the grammar and the
/// per-prompt whitelists unambiguous.
fn is_identifier(candidate: &str) -> bool {
    let mut chars = candidate.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return false;
    }
    chars.all(|character| character.is_ascii_alphanumeric() || character == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vars(pairs: &[(&'static str, &str)]) -> BTreeMap<&'static str, String> {
        pairs
            .iter()
            .map(|(name, value)| (*name, (*value).to_string()))
            .collect()
    }

    #[test]
    fn substitutes_named_variables_with_surrounding_whitespace_tolerance() {
        let template = PromptTemplate::new("Title: {{ title }}\nBody: {{body}}");
        let rendered = template
            .render(&vars(&[("title", "Fix bug"), ("body", "steps")]))
            .expect("render");
        assert_eq!(rendered, "Title: Fix bug\nBody: steps");
    }

    #[test]
    fn unavailable_variable_fails_the_render() {
        let template = PromptTemplate::new("PR: {{ pull_request }}");
        let error = template.render(&vars(&[])).expect_err("missing var fails");
        assert_eq!(error.variable, "pull_request");
    }

    #[test]
    fn single_braces_and_embedded_json_pass_through() {
        let template = PromptTemplate::new("json: {{ payload }}");
        let rendered = template
            .render(&vars(&[("payload", "{\n  \"a\": 1\n}")]))
            .expect("render");
        assert_eq!(rendered, "json: {\n  \"a\": 1\n}");
    }

    #[test]
    fn inserted_values_are_not_rescanned() {
        let template = PromptTemplate::new("{{ body }}");
        let rendered = template
            .render(&vars(&[("body", "literal {{ title }} here")]))
            .expect("render");
        assert_eq!(rendered, "literal {{ title }} here");
    }

    #[test]
    fn unclosed_or_invalid_placeholders_stay_literal() {
        let template = PromptTemplate::new("a {{ not closed and b {{ 1bad }} c");
        assert!(template.referenced_variables().is_empty());
        let rendered = template.render(&vars(&[])).expect("render");
        assert_eq!(rendered, "a {{ not closed and b {{ 1bad }} c");
    }

    #[test]
    fn referenced_variables_are_the_distinct_valid_names() {
        let template = PromptTemplate::new("{{ title }} {{ title }} {{ body }}");
        let names = template.referenced_variables();
        assert_eq!(names.len(), 2);
        assert!(names.contains("title"));
        assert!(names.contains("body"));
    }

    #[test]
    fn empty_and_whitespace_only_placeholders_stay_literal() {
        let template = PromptTemplate::new("a {{}} b {{   }} c");
        assert!(template.referenced_variables().is_empty());
        let rendered = template.render(&vars(&[])).expect("render");
        assert_eq!(rendered, "a {{}} b {{   }} c");
    }

    #[test]
    fn render_error_message_names_the_unavailable_variable() {
        let template = PromptTemplate::new("PR: {{ pull_request }}");
        let error = template.render(&vars(&[])).expect_err("missing var fails");
        assert_eq!(
            error.to_string(),
            "prompt variable 'pull_request' is not available for this item"
        );
    }

    #[test]
    fn config_error_message_lists_every_unknown_name() {
        let template = PromptTemplate::new("{{ titel }} {{ boddy }}");
        let error = template
            .validate_names(&["title", "body"])
            .expect_err("typos rejected");
        assert_eq!(
            error.to_string(),
            "prompt references unknown variables: boddy, titel"
        );
    }

    #[test]
    fn validate_names_rejects_names_outside_the_whitelist() {
        let template = PromptTemplate::new("{{ title }} {{ titel }}");
        let error = template
            .validate_names(&["title", "body"])
            .expect_err("typo rejected");
        assert_eq!(error.unknown, vec!["titel".to_string()]);
        template
            .validate_names(&["title", "titel"])
            .expect("all known");
    }
}
