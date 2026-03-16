use std::fs;

use crate::context::{CurrentRunRecord, RunLayout, RunMetadata};
use crate::core_defs::{current_run_context_path, shorten_path, utc_now};
use crate::errors::{CliError, CliErrorKind, cow};
use crate::io::append_markdown_row;
use crate::resolve::resolve_suite_path;
use crate::schema::{RunCounts, RunReport, RunReportFrontmatter, RunStatus, SuiteSpec, Verdict};
use crate::workflow::runner::initialize_runner_state;

use super::shared::{resolve_init_repo_root, resolve_run_root};

/// Initialize a new test run directory.
///
/// # Errors
/// Returns `CliError` on failure.
///
/// # Panics
/// Panics if metadata or status structs fail to serialize (should never happen).
pub fn init_run(
    suite: &str,
    run_id: &str,
    profile: &str,
    repo_root: Option<&str>,
    run_root: Option<&str>,
) -> Result<i32, CliError> {
    let suite_path = resolve_suite_path(suite)?;
    let spec = SuiteSpec::from_markdown(&suite_path)?;
    let suite_dir = spec.suite_dir().to_path_buf();
    let resolved_repo_root = resolve_init_repo_root(repo_root, &suite_dir);
    let resolved_run_root = resolve_run_root(run_root, Some(&suite_dir));
    let created_at = utc_now();

    let layout = RunLayout {
        run_root: resolved_run_root.to_string_lossy().into_owned(),
        run_id: run_id.to_string(),
    };

    if layout.run_dir().exists() {
        return Err(CliErrorKind::run_dir_exists(layout.run_dir().display().to_string()).into());
    }

    layout.ensure_dirs()?;

    let metadata = RunMetadata {
        run_id: run_id.to_string(),
        suite_id: spec.frontmatter.suite_id.clone(),
        suite_path: suite_path.to_string_lossy().into_owned(),
        suite_dir: suite_dir.to_string_lossy().into_owned(),
        profile: profile.to_string(),
        repo_root: resolved_repo_root.to_string_lossy().into_owned(),
        keep_clusters: spec.frontmatter.keep_clusters,
        created_at: created_at.clone(),
        user_stories: spec.frontmatter.user_stories.clone(),
        required_dependencies: spec.frontmatter.required_dependencies.clone(),
    };

    let meta_json = serde_json::to_string_pretty(&metadata)
        .map_err(|e| CliErrorKind::serialize(cow!("run metadata: {e}")))?;
    fs::write(layout.metadata_path(), format!("{meta_json}\n"))?;

    let status = RunStatus {
        run_id: run_id.to_string(),
        suite_id: spec.frontmatter.suite_id.clone(),
        profile: profile.to_string(),
        started_at: created_at,
        overall_verdict: Verdict::Pending,
        completed_at: None,
        counts: RunCounts::default(),
        executed_groups: vec![],
        skipped_groups: vec![],
        last_completed_group: None,
        last_state_capture: None,
        last_updated_utc: None,
        next_planned_group: None,
        notes: vec![],
    };
    let status_json = serde_json::to_string_pretty(&status)
        .map_err(|e| CliErrorKind::serialize(cow!("run status: {e}")))?;
    fs::write(layout.status_path(), format!("{status_json}\n"))?;

    initialize_runner_state(&layout.run_dir())?;

    let command_log = layout.commands_dir().join("command-log.md");
    append_markdown_row(
        &command_log,
        &["ran_at", "command", "exit_code", "artifact"],
        &["(init)", "harness init", "0", "-"],
    )?;

    let manifest_index = layout.manifests_dir().join("manifest-index.md");
    append_markdown_row(
        &manifest_index,
        &["copied_at", "manifest", "validated", "applied", "notes"],
        &["(init)", "-", "-", "-", "index created"],
    )?;

    let report = RunReport::new(
        layout.report_path(),
        RunReportFrontmatter {
            run_id: run_id.to_string(),
            suite_id: spec.frontmatter.suite_id.clone(),
            profile: profile.to_string(),
            overall_verdict: Verdict::Pending,
            story_results: vec![],
            debug_summary: vec![],
        },
        "# Run Report\n".to_string(),
    );
    report.save()?;

    let record = CurrentRunRecord {
        layout: layout.clone(),
        profile: Some(profile.to_string()),
        repo_root: Some(resolved_repo_root.to_string_lossy().into_owned()),
        suite_dir: Some(suite_dir.to_string_lossy().into_owned()),
        suite_id: Some(spec.frontmatter.suite_id.clone()),
        suite_path: Some(suite_path.to_string_lossy().into_owned()),
        cluster: None,
        keep_clusters: spec.frontmatter.keep_clusters,
        user_stories: spec.frontmatter.user_stories.clone(),
        required_dependencies: spec.frontmatter.required_dependencies.clone(),
    };
    let ctx_path = current_run_context_path()?;
    if let Some(parent) = ctx_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let record_json = serde_json::to_string_pretty(&record)
        .map_err(|e| CliErrorKind::serialize(cow!("run context record: {e}")))?;
    fs::write(&ctx_path, format!("{record_json}\n"))?;

    println!("{}", shorten_path(&layout.run_dir()));
    Ok(0)
}
