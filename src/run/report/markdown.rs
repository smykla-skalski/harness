use std::borrow::Cow;
use std::fmt::Write as _;

use super::RunReport;

pub(super) fn render_report(report: &RunReport) -> String {
    let fm = &report.frontmatter;
    let mut out = String::new();
    writeln!(out, "---").unwrap();
    writeln!(out, "run_id: {}", fm.run_id).unwrap();
    writeln!(out, "suite_id: {}", fm.suite_id).unwrap();
    writeln!(out, "profile: {}", fm.profile).unwrap();
    writeln!(out, "overall_verdict: {}", fm.overall_verdict).unwrap();
    render_frontmatter_list_into(&mut out, "story_results", &fm.story_results);
    render_frontmatter_list_into(&mut out, "debug_summary", &fm.debug_summary);
    writeln!(out, "---").unwrap();
    writeln!(out).unwrap();
    writeln!(out, "{}", report.body.trim_end()).unwrap();
    out
}

fn render_frontmatter_list_into(out: &mut String, key: &str, values: &[String]) {
    if values.is_empty() {
        writeln!(out, "{key}: []").unwrap();
        return;
    }
    writeln!(out, "{key}:").unwrap();
    for value in values {
        writeln!(out, "  - {}", yaml_quote_if_needed(value)).unwrap();
    }
}

fn yaml_quote_if_needed(value: &str) -> Cow<'_, str> {
    const SPECIAL: &[char] = &[':', '#', '`', '[', ']', '{', '}', '&', '*', '!', '%'];
    if value.contains(SPECIAL) {
        let escaped = value.replace('\'', "''");
        Cow::Owned(format!("'{escaped}'"))
    } else {
        Cow::Borrowed(value)
    }
}
