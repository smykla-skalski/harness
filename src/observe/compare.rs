use std::collections::HashSet;

use serde::Serialize;

use crate::errors::CliError;

use super::scan::scan_range;
use super::session;
use super::types::Issue;

#[derive(Serialize)]
struct ComparedRange {
    from: usize,
    to: usize,
    issues: usize,
}

#[derive(Serialize)]
struct ComparedIssue<'a> {
    issue_id: &'a str,
    code: String,
    summary: &'a str,
}

#[derive(Serialize)]
struct CompareResult<'a> {
    range_a: ComparedRange,
    range_b: ComparedRange,
    new: usize,
    resolved: usize,
    unchanged: usize,
    new_issues: Vec<ComparedIssue<'a>>,
    resolved_issues: Vec<ComparedIssue<'a>>,
}

/// Compare issues between two line ranges in the same session.
pub(super) fn execute_compare(
    session_id: &str,
    from_a: usize,
    to_a: usize,
    from_b: usize,
    to_b: usize,
    project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let path = session::find_session(session_id, project_hint)?;

    let (issues_a, _) = scan_range(&path, from_a, to_a)?;
    let (issues_b, _) = scan_range(&path, from_b, to_b)?;

    let ids_a: HashSet<_> = issues_a.iter().map(|i| &i.id).collect();
    let ids_b: HashSet<_> = issues_b.iter().map(|i| &i.id).collect();

    let new_issues: Vec<&Issue> = issues_b
        .iter()
        .filter(|i| !ids_a.contains(&&i.id))
        .collect();
    let resolved_issues: Vec<&Issue> = issues_a
        .iter()
        .filter(|i| !ids_b.contains(&&i.id))
        .collect();
    let unchanged_count = ids_a.intersection(&ids_b).count();

    let result = CompareResult {
        range_a: ComparedRange {
            from: from_a,
            to: to_a,
            issues: issues_a.len(),
        },
        range_b: ComparedRange {
            from: from_b,
            to: to_b,
            issues: issues_b.len(),
        },
        new: new_issues.len(),
        resolved: resolved_issues.len(),
        unchanged: unchanged_count,
        new_issues: new_issues
            .iter()
            .map(|issue| ComparedIssue {
                issue_id: &issue.id,
                code: issue.code.to_string(),
                summary: &issue.summary,
            })
            .collect(),
        resolved_issues: resolved_issues
            .iter()
            .map(|issue| ComparedIssue {
                issue_id: &issue.id,
                code: issue.code.to_string(),
                summary: &issue.summary,
            })
            .collect(),
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&result).expect("valid compare JSON")
    );
    Ok(0)
}
