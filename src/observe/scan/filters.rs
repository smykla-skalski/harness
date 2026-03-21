use std::fs;

use crate::errors::{CliError, CliErrorKind};

use super::super::application::ObserveFilter;
use super::super::types::{FocusPreset, Issue, IssueCategory, IssueCode, IssueSeverity};

/// Apply focus/category filters, returning an error for invalid values.
pub(crate) fn apply_filters(
    issues: Vec<Issue>,
    filter: &ObserveFilter,
) -> Result<Vec<Issue>, CliError> {
    let mut filtered = issues;

    if let Some(ref severity) = filter.severity {
        let Some(min_severity) = IssueSeverity::from_label(severity) else {
            return Err(CliErrorKind::session_parse_error(format!(
                "unknown severity '{severity}'. Valid: low, medium, critical"
            ))
            .into());
        };
        filtered.retain(|issue| issue.severity >= min_severity);
    }

    apply_category_filter(&mut filtered, filter)?;

    if let Some(ref exclude) = filter.exclude {
        let excluded: Vec<IssueCategory> = exclude
            .split(',')
            .filter_map(|c| IssueCategory::from_label(c.trim()))
            .collect();
        filtered.retain(|issue| !excluded.contains(&issue.category));
    }

    if filter.fixable {
        filtered.retain(|issue| issue.fix_safety.is_fixable());
    }

    if let Some(ref mute) = filter.mute {
        let muted: Vec<IssueCode> = mute
            .split(',')
            .filter_map(|c| IssueCode::from_label(c.trim()))
            .collect();
        filtered.retain(|issue| !muted.contains(&issue.code));
    }

    if let Some(ref overrides_path) = filter.overrides {
        apply_overrides_file(&mut filtered, overrides_path)?;
    }

    Ok(filtered)
}

fn apply_category_filter(
    filtered: &mut Vec<Issue>,
    filter: &ObserveFilter,
) -> Result<(), CliError> {
    if let Some(ref focus) = filter.focus {
        let Some(preset) = FocusPreset::from_label(focus) else {
            return Err(CliErrorKind::session_parse_error(format!(
                "unknown focus preset '{focus}'. Valid: harness, skills, all"
            ))
            .into());
        };
        let Some(focus_categories) = preset.categories() else {
            return Ok(());
        };
        if let Some(ref category) = filter.category {
            let explicit: Vec<IssueCategory> = category
                .split(',')
                .filter_map(|c| IssueCategory::from_label(c.trim()))
                .collect();
            filtered.retain(|issue| {
                focus_categories.contains(&issue.category) && explicit.contains(&issue.category)
            });
        } else {
            filtered.retain(|issue| focus_categories.contains(&issue.category));
        }
    } else if let Some(ref category) = filter.category {
        let categories: Vec<IssueCategory> = category
            .split(',')
            .filter_map(|c| IssueCategory::from_label(c.trim()))
            .collect();
        if categories.is_empty() {
            return Err(CliErrorKind::session_parse_error(format!(
                "no valid categories in '{category}'. Valid: {}",
                IssueCategory::ALL
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(", ")
            ))
            .into());
        }
        filtered.retain(|issue| categories.contains(&issue.category));
    }
    Ok(())
}

fn apply_overrides_file(filtered: &mut Vec<Issue>, overrides_path: &str) -> Result<(), CliError> {
    let content = fs::read_to_string(overrides_path).map_err(|e| {
        CliErrorKind::session_parse_error(format!("cannot read overrides file: {e}"))
    })?;
    let overrides: serde_json::Value = serde_yml::from_str(&content)
        .map_err(|e| CliErrorKind::session_parse_error(format!("invalid overrides YAML: {e}")))?;

    if let Some(mute_list) = overrides["mute"].as_array() {
        let muted: Vec<IssueCode> = mute_list
            .iter()
            .filter_map(|v| v.as_str().and_then(IssueCode::from_label))
            .collect();
        filtered.retain(|issue| !muted.contains(&issue.code));
    }

    if let Some(overrides_map) = overrides["severity_overrides"].as_object() {
        for issue in filtered.iter_mut() {
            let code_str = issue.code.to_string();
            if let Some(new_sev) = overrides_map
                .get(&code_str)
                .and_then(|v| v.as_str())
                .and_then(IssueSeverity::from_label)
            {
                issue.severity = new_sev;
            }
        }
    }
    Ok(())
}
