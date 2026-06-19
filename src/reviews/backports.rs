use regex::Regex;

use crate::errors::{CliError, CliErrorKind};

use super::{ReviewBackportSource, ReviewsQueryRequest, ReviewsRefreshRequest};

#[derive(Debug)]
pub(super) struct BackportDetector {
    patterns: Vec<Regex>,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct BackportDetection {
    pub(super) title: String,
    pub(super) source: ReviewBackportSource,
}

impl BackportDetector {
    pub(super) fn from_query(request: &ReviewsQueryRequest) -> Result<Option<Self>, CliError> {
        Self::compile(
            request.backport_detection_enabled,
            &request.normalized_backport_patterns(),
        )
    }

    pub(super) fn from_refresh(request: &ReviewsRefreshRequest) -> Result<Option<Self>, CliError> {
        Self::compile(
            request.backport_detection_enabled,
            &request.normalized_backport_patterns(),
        )
    }

    pub(super) fn validate_patterns(patterns: &[String]) -> Result<(), CliError> {
        for pattern in patterns {
            let pattern = pattern.trim();
            if pattern.is_empty() {
                continue;
            }
            compile_pattern(pattern)?;
        }
        Ok(())
    }

    fn compile(enabled: bool, patterns: &[String]) -> Result<Option<Self>, CliError> {
        if !enabled {
            return Ok(None);
        }
        let mut compiled = Vec::with_capacity(patterns.len());
        for pattern in patterns {
            let pattern = pattern.trim();
            if pattern.is_empty() {
                continue;
            }
            compiled.push(compile_pattern(pattern)?);
        }
        if compiled.is_empty() {
            return Ok(None);
        }
        Ok(Some(Self { patterns: compiled }))
    }

    pub(super) fn detect(&self, repository: &str, title: &str) -> Option<BackportDetection> {
        for pattern in &self.patterns {
            let Some(captures) = pattern.captures(title) else {
                continue;
            };
            let Some(number_match) = captures.name("number").or_else(|| captures.get(1)) else {
                continue;
            };
            let Ok(number) = number_match.as_str().parse() else {
                continue;
            };
            let Some(matched) = captures.get(0) else {
                continue;
            };
            let Some(stripped_title) = stripped_title(title, matched.start(), matched.end()) else {
                continue;
            };
            return Some(BackportDetection {
                title: stripped_title,
                source: ReviewBackportSource {
                    number,
                    repository: repository.to_owned(),
                    url: format!("https://github.com/{repository}/pull/{number}"),
                },
            });
        }
        None
    }
}

fn compile_pattern(pattern: &str) -> Result<Regex, CliError> {
    Regex::new(pattern).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "invalid reviews backport pattern '{pattern}': {error}"
        ))
        .into()
    })
}

fn stripped_title(title: &str, start: usize, end: usize) -> Option<String> {
    let mut stripped = String::with_capacity(title.len().saturating_sub(end - start));
    stripped.push_str(title[..start].trim_end());
    stripped.push_str(title[end..].trim_start());
    let stripped = stripped.trim();
    if stripped.is_empty() {
        return None;
    }
    Some(stripped.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detector() -> BackportDetector {
        let request = ReviewsQueryRequest::default();
        BackportDetector::from_query(&request)
            .expect("detector")
            .expect("enabled detector")
    }

    #[test]
    fn detects_parenthesized_backport_suffix_and_strips_title() {
        let result = detector()
            .detect(
                "kumahq/kuma",
                "chore(deps): bump envoy from 1.36.7 to 1.36.8 (backport of #16926)",
            )
            .expect("backport detected");

        assert_eq!(
            result.title,
            "chore(deps): bump envoy from 1.36.7 to 1.36.8"
        );
        assert_eq!(result.source.number, 16926);
        assert_eq!(result.source.repository, "kumahq/kuma");
        assert_eq!(
            result.source.url,
            "https://github.com/kumahq/kuma/pull/16926"
        );
    }

    #[test]
    fn returns_none_without_a_configured_match() {
        assert!(
            detector()
                .detect("kumahq/kuma", "chore(deps): bump envoy")
                .is_none()
        );
    }

    #[test]
    fn validates_configured_patterns() {
        let patterns = vec!["(".to_owned()];

        assert!(BackportDetector::validate_patterns(&patterns).is_err());
    }
}
