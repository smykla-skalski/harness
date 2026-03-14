use std::path::{Path, PathBuf};

use serde_json::json;

use crate::context::{RunLayout, RunMetadata};
use crate::core_defs::utc_now;
use crate::errors::{self, CliError};
use crate::io::write_text;
use crate::resolve::resolve_suite_path;
use crate::schema::{RunReport, RunReportFrontmatter, RunStatus, SuiteSpec};
use crate::suite_defaults::default_repo_root_for_suite;
use crate::workflow::runner::initialize_runner_state;

fn resolve_repo_root(raw: Option<&str>, suite_dir: &Path) -> PathBuf {
    if let Some(r) = raw {
        return PathBuf::from(r)
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(r));
    }
    if let Some(default) = default_repo_root_for_suite(suite_dir) {
        return default;
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn resolve_run_root(raw: Option<&str>) -> PathBuf {
    if let Some(r) = raw {
        return PathBuf::from(r);
    }
    crate::core_defs::harness_data_root().join("runs")
}

/// Initialize a new test run directory.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(
    suite: &str,
    run_id: &str,
    profile: &str,
    repo_root: Option<&str>,
    run_root: Option<&str>,
) -> Result<i32, CliError> {
    let suite_path = resolve_suite_path(suite)?;
    let spec = SuiteSpec::from_markdown(&suite_path)?;
    let suite_dir = spec.suite_dir().to_path_buf();
    let resolved_repo_root = resolve_repo_root(repo_root, &suite_dir);
    let resolved_run_root = resolve_run_root(run_root);
    let created_at = utc_now();

    let layout = RunLayout {
        run_root: resolved_run_root.to_string_lossy().to_string(),
        run_id: run_id.to_string(),
    };

    if layout.run_dir().exists() {
        return Err(errors::cli_err(
            &errors::RUN_DIR_EXISTS,
            &[("run_dir", &layout.run_dir().display().to_string())],
        ));
    }

    layout.ensure_dirs().map_err(|e| CliError {
        code: "IO".to_string(),
        message: format!("failed to create run directories: {e}"),
        exit_code: 1,
        hint: None,
        details: None,
    })?;

    let metadata = RunMetadata {
        run_id: run_id.to_string(),
        suite_id: spec.frontmatter.suite_id.clone(),
        suite_path: suite_path.to_string_lossy().to_string(),
        suite_dir: suite_dir.to_string_lossy().to_string(),
        profile: profile.to_string(),
        repo_root: resolved_repo_root.to_string_lossy().to_string(),
        keep_clusters: spec.frontmatter.keep_clusters,
        created_at: created_at.clone(),
        user_stories: spec.frontmatter.user_stories.clone(),
        required_dependencies: spec.frontmatter.required_dependencies.clone(),
    };

    let meta_json = serde_json::to_string_pretty(&metadata).unwrap_or_default();
    std::fs::write(layout.metadata_path(), format!("{meta_json}\n")).map_err(|e| CliError {
        code: "IO".to_string(),
        message: format!("failed to write metadata: {e}"),
        exit_code: 1,
        hint: None,
        details: None,
    })?;

    let status = RunStatus {
        run_id: run_id.to_string(),
        suite_id: spec.frontmatter.suite_id.clone(),
        profile: profile.to_string(),
        started_at: created_at,
        overall_verdict: "pending".to_string(),
        completed_at: None,
        counts: crate::schema::RunCounts::default(),
        executed_groups: vec![],
        skipped_groups: vec![],
        last_completed_group: None,
        last_state_capture: None,
        last_updated_utc: None,
        next_planned_group: None,
        notes: vec![],
    };
    let status_json = serde_json::to_string_pretty(&status).unwrap_or_default();
    std::fs::write(layout.status_path(), format!("{status_json}\n")).map_err(|e| CliError {
        code: "IO".to_string(),
        message: format!("failed to write status: {e}"),
        exit_code: 1,
        hint: None,
        details: None,
    })?;

    initialize_runner_state(&layout.run_dir())?;

    let command_log = layout.commands_dir().join("command-log.md");
    crate::io::append_markdown_row(
        &command_log,
        &["ran_at", "command", "exit_code", "artifact"],
        &["(init)", "harness init", "0", "-"],
    )?;

    let manifest_index = layout.manifests_dir().join("manifest-index.md");
    crate::io::append_markdown_row(
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
            overall_verdict: "pending".to_string(),
            story_results: vec![],
            debug_summary: vec![],
        },
        "# Run Report\n".to_string(),
    );
    report.save()?;

    println!("{}", layout.run_dir().display());
    Ok(0)
}
