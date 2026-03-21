use std::fmt::Write as _;

use super::types::{Issue, IssueSeverity};

#[path = "output/rendering.rs"]
mod rendering;

use self::rendering::{
    RenderedIssue, RenderedMarkdownRow, RenderedSummary, RenderedTopCauses, SarifProperties,
    render_json_pretty_string, render_json_string, render_property_bag,
};

/// Render an issue as a human-readable line.
#[must_use]
pub fn render_human(issue: &Issue) -> String {
    let severity = issue.severity.to_string().to_uppercase();
    let confidence = issue.confidence.to_string();
    let mut rendered = format!(
        "[{severity}/{confidence}] L{} ({}/{}): {}",
        issue.line, issue.category, issue.code, issue.summary
    );
    if let Some(ref target) = issue.fix_target {
        let _ = write!(rendered, "\n  fix: {target}");
    }
    if let Some(ref hint) = issue.fix_hint {
        let _ = write!(rendered, "\n  hint: {hint}");
    }
    rendered
}

/// Render an issue as a JSON string with truncated details.
#[must_use]
pub fn render_json(issue: &Issue) -> String {
    render_json_string(&RenderedIssue::from(issue))
}

/// Render a summary JSON object with counts by severity and category.
#[must_use]
pub fn render_summary(issues: &[Issue], last_line: usize) -> String {
    render_json_string(&RenderedSummary::new(issues, last_line))
}

/// Render issues as a markdown report using `tabled` for table formatting.
#[must_use]
pub fn render_markdown(issues: &[Issue]) -> String {
    use tabled::Table;
    use tabled::settings::Style;

    if issues.is_empty() {
        return "# Observe report\n\nNo issues found.\n".to_string();
    }

    let rows: Vec<_> = issues.iter().map(RenderedMarkdownRow::from).collect();
    let table = Table::new(&rows).with(Style::markdown()).to_string();
    let mut output = String::from("# Observe report\n\n");
    output.push_str(&table);
    let _ = write!(output, "\n\n**Total: {} issues**\n", issues.len());
    output
}

/// Render top N root causes grouped by issue code.
#[must_use]
pub fn render_top_causes(issues: &[Issue], top_n: usize) -> String {
    render_json_string(&RenderedTopCauses::new(issues, top_n))
}

/// Render issues in SARIF (Static Analysis Results Interchange Format) v2.1.0.
#[must_use]
pub fn render_sarif(issues: &[Issue]) -> String {
    use serde_sarif::sarif::{
        ArtifactLocation, Location, Message, PhysicalLocation, Region, Result as SarifResult,
        ResultLevel, Run, Sarif, Tool, ToolComponent,
    };

    let results: Vec<SarifResult> = issues
        .iter()
        .map(|issue| {
            let level = match issue.severity {
                IssueSeverity::Critical => ResultLevel::Error,
                IssueSeverity::Medium => ResultLevel::Warning,
                IssueSeverity::Low => ResultLevel::Note,
            };

            let uri = issue
                .fix_target
                .as_deref()
                .unwrap_or("session.jsonl")
                .to_string();
            let line = i64::try_from(issue.line).unwrap_or(i64::MAX);

            let location = Location::builder()
                .physical_location(
                    PhysicalLocation::builder()
                        .artifact_location(ArtifactLocation::builder().uri(uri).build())
                        .region(Region::builder().start_line(line).build())
                        .build(),
                )
                .build();

            SarifResult::builder()
                .message(Message::builder().text(issue.summary.clone()).build())
                .rule_id(issue.code.to_string())
                .level(level)
                .locations(vec![location])
                .properties(render_property_bag(&SarifProperties::from_issue(issue)))
                .build()
        })
        .collect();

    let driver = ToolComponent::builder()
        .name("harness-observe".to_string())
        .version(env!("CARGO_PKG_VERSION").to_string())
        .information_uri("https://github.com/smykla-skalski/harness".to_string())
        .build();

    let run = Run::builder()
        .tool(Tool::builder().driver(driver).build())
        .results(results)
        .build();

    let sarif = Sarif::builder()
        .schema("https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json".to_string())
        .version(serde_json::Value::String("2.1.0".to_string()))
        .runs(vec![run])
        .build();

    render_json_pretty_string(&sarif)
}
#[cfg(test)]
#[path = "output/tests.rs"]
mod tests;
