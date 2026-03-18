use std::fs;
use std::path::Path;

use clap::Args;

use crate::audit_log::write_run_status_with_audit;
use crate::context::{CurrentRunPointer, RunLayout, RunMetadata, RunRepository};
use crate::core_defs::{shorten_path, utc_now};
use crate::errors::{CliError, CliErrorKind, cow};
use crate::io::{validate_safe_segment, write_json_pretty};
use crate::resolve::resolve_suite_path;
use crate::schema::{RunCounts, RunReport, RunReportFrontmatter, RunStatus, SuiteSpec, Verdict};
use crate::workflow::runner::initialize_runner_state;

use super::shared::{resolve_init_repo_root, resolve_run_root};

/// Arguments for `harness init`.
#[derive(Debug, Clone, Args)]
pub struct InitArgs {
    /// Suite Markdown path or name.
    #[arg(long)]
    pub suite: String,
    /// Run ID to create under the run root.
    #[arg(long)]
    pub run_id: String,
    /// Suite profile to run (e.g. single-zone or multi-zone).
    #[arg(long)]
    pub profile: String,
    /// Repo root to record in run metadata.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Parent directory to create the run in.
    #[arg(long)]
    pub run_root: Option<String>,
}

/// Parameters that identify the run being initialized.
struct RunParams<'a> {
    run_id: &'a str,
    profile: &'a str,
    created_at: &'a str,
}

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
    validate_safe_segment(run_id)?;
    let suite_path = resolve_suite_path(suite)?;
    let spec = SuiteSpec::from_markdown(&suite_path)?;
    let suite_dir = spec.suite_dir().to_path_buf();
    let resolved_repo_root = resolve_init_repo_root(repo_root, &suite_dir)?;
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

    let params = RunParams {
        run_id,
        profile,
        created_at: &created_at,
    };
    let result = populate_run_dir(
        &layout,
        &spec,
        &suite_path,
        &suite_dir,
        &resolved_repo_root,
        &params,
    );
    if result.is_err() {
        let _ = fs::remove_dir_all(layout.run_dir());
    }
    result
}

fn populate_run_dir(
    layout: &RunLayout,
    spec: &SuiteSpec,
    suite_path: &Path,
    suite_dir: &Path,
    resolved_repo_root: &Path,
    params: &RunParams<'_>,
) -> Result<i32, CliError> {
    let run_id = params.run_id;
    let profile = params.profile;
    let created_at = params.created_at;
    let suite_id = spec.frontmatter.suite_id.clone();
    let user_stories = spec.frontmatter.user_stories.clone();
    let required_dependencies = spec.frontmatter.required_dependencies.clone();
    let requires = spec.frontmatter.effective_requires();

    let metadata = RunMetadata {
        run_id: run_id.to_string(),
        suite_id: suite_id.clone(),
        suite_path: suite_path.to_string_lossy().into_owned(),
        suite_dir: suite_dir.to_string_lossy().into_owned(),
        profile: profile.to_string(),
        repo_root: resolved_repo_root.to_string_lossy().into_owned(),
        keep_clusters: spec.frontmatter.keep_clusters,
        created_at: created_at.to_string(),
        user_stories,
        required_dependencies,
        requires,
    };

    write_json_pretty(&layout.metadata_path(), &metadata)
        .map_err(|e| CliErrorKind::serialize(cow!("run metadata: {e}")))?;

    let status = RunStatus {
        run_id: run_id.to_string(),
        suite_id: suite_id.clone(),
        profile: profile.to_string(),
        started_at: created_at.to_string(),
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
    write_run_status_with_audit(&layout.run_dir(), &status, None, Some("bootstrap"), None)?;

    initialize_runner_state(&layout.run_dir())?;

    layout.append_command_log("(init)", "bootstrap", "-", "harness init", "0", "-")?;
    layout.append_manifest_index("(init)", "-", "-", "-", "index created")?;

    let report = RunReport::new(
        layout.report_path(),
        RunReportFrontmatter {
            run_id: run_id.to_string(),
            suite_id,
            profile: profile.to_string(),
            overall_verdict: Verdict::Pending,
            story_results: vec![],
            debug_summary: vec![],
        },
        "# Run Report\n".to_string(),
    );
    report.save()?;

    let pointer = CurrentRunPointer::from_metadata(layout.clone(), &metadata, None);
    let repo = RunRepository;
    repo.save_current_pointer(&pointer)
        .map_err(|e| CliErrorKind::serialize(cow!("run context record: {e}")))?;

    println!("{}", shorten_path(&layout.run_dir()));
    Ok(0)
}
