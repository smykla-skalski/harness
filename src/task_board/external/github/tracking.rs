use std::sync::LazyLock;

use regex::Regex;

use super::super::{ExternalProvider, ExternalTaskRef};
use super::GitHubRepository;

// GitHub sub-issues are unused in practice here; issues declare hierarchy in
// body text instead ("Part of #N" on the child, a "- [ ] #N" checklist on the
// tracking issue).
static PARENT_REFERENCE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)part of\s+(?:([\w.-]+/[\w.-]+))?#(\d+)").expect("valid regex")
});

static CHILD_CHECKLIST_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^[ \t]*[-*][ \t]*\[[ xX]\][ \t]*(?:[\w.-]+/[\w.-]+)?#\d+")
        .expect("valid regex")
});

pub(super) fn parent_reference_in_body(
    repository: &GitHubRepository,
    body: &str,
) -> Option<ExternalTaskRef> {
    let captures = PARENT_REFERENCE_RE.captures(body)?;
    let issue_number = captures.get(2)?.as_str();
    let repository_slug = captures
        .get(1)
        .map_or_else(|| repository.slug(), |repo| repo.as_str().to_owned());
    Some(ExternalTaskRef::new(
        ExternalProvider::GitHub,
        format!("{repository_slug}#{issue_number}"),
    ))
}

pub(super) fn body_lists_child_issues(body: &str) -> bool {
    CHILD_CHECKLIST_RE.is_match(body)
}

#[cfg(test)]
mod tests;
