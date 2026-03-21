use super::super::application::ObserveFilter;
use super::super::output;
use super::super::types::Issue;

/// Render scan results to stdout using the requested format.
pub(super) fn render_scan_output(filter: &ObserveFilter, issues: &[Issue], last_line: usize) {
    render_scan_issues(filter, issues);
    render_scan_followups(filter, issues, last_line);
}

fn render_scan_issues(filter: &ObserveFilter, issues: &[Issue]) {
    match filter.format.as_deref().unwrap_or("") {
        "markdown" | "md" => println!("{}", output::render_markdown(issues)),
        "sarif" => println!("{}", output::render_sarif(issues)),
        _ if filter.json => {
            for issue in issues {
                println!("{}", output::render_json(issue));
            }
        }
        _ => {
            for issue in issues {
                println!("{}", output::render_human(issue));
            }
        }
    }
}

fn render_scan_followups(filter: &ObserveFilter, issues: &[Issue], last_line: usize) {
    if let Some(n) = filter.top_causes {
        println!("{}", output::render_top_causes(issues, n));
    }
    if filter.summary {
        println!("{}", output::render_summary(issues, last_line));
    }
}
