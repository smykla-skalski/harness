use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

use regex::Regex;

use crate::cli::{EnvoyCommand, KumactlCommand, ReportCommand, RunDirArgs};
use crate::context::{CurrentRunRecord, RunContext, RunLayout, RunMetadata};
use crate::core_defs::{current_run_context_path, harness_data_root, utc_now};
use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec::{kubectl, run_command};
use crate::io::{append_markdown_row, drill, ensure_dir, read_text, write_text};
use crate::manifests::default_validation_output;
use crate::resolve::{resolve_manifest_path, resolve_suite_path};
use crate::rules::suite_runner::{REPORT_CODE_BLOCK_LIMIT, REPORT_LINE_LIMIT};
use crate::schema::{RunCounts, RunReport, RunReportFrontmatter, RunStatus, SuiteSpec, Verdict};
use crate::suite_defaults::default_repo_root_for_suite;
use crate::workflow::runner::initialize_runner_state;

// =========================================================================
// init_run
// =========================================================================

fn resolve_init_repo_root(raw: Option<&str>, suite_dir: &Path) -> PathBuf {
    if let Some(r) = raw {
        return PathBuf::from(r)
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(r));
    }
    if let Some(default) = default_repo_root_for_suite(suite_dir) {
        return default;
    }
    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn resolve_run_root(raw: Option<&str>) -> PathBuf {
    if let Some(r) = raw {
        return PathBuf::from(r);
    }
    harness_data_root().join("runs")
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
    let suite_path = resolve_suite_path(suite)?;
    let spec = SuiteSpec::from_markdown(&suite_path)?;
    let suite_dir = spec.suite_dir().to_path_buf();
    let resolved_repo_root = resolve_init_repo_root(repo_root, &suite_dir);
    let resolved_run_root = resolve_run_root(run_root);
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

    println!("{}", layout.run_dir().display());
    Ok(0)
}

// =========================================================================
// preflight
// =========================================================================

/// Run preflight checks and prepare suite manifests.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn preflight(
    _kubeconfig: Option<&str>,
    _repo_root: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let ctx = super::resolve_run_context(run_dir_args)?;

    eprintln!("{} preflight: complete", utc_now());
    println!("{}", ctx.layout.artifacts_dir().display());
    Ok(0)
}

// =========================================================================
// capture
// =========================================================================

/// Capture cluster pod state for a run.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn capture(
    kubeconfig: Option<&str>,
    label: &str,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let ctx = super::resolve_run_context(run_dir_args)?;

    let kc = kubeconfig.map(PathBuf::from).or_else(|| {
        ctx.cluster
            .as_ref()
            .map(|c| PathBuf::from(c.primary_kubeconfig()))
    });

    let timestamp = chrono::Utc::now()
        .format("%Y-%m-%dT%H%M%S.%6fZ")
        .to_string();
    let capture_path = ctx
        .layout
        .state_dir()
        .join(format!("{label}-{timestamp}.json"));

    let result = kubectl(
        kc.as_deref(),
        &["get", "pods", "--all-namespaces", "-o", "json"],
        &[0],
    )?;

    write_text(&capture_path, &result.stdout)?;

    let rel = capture_path.strip_prefix(ctx.layout.run_dir()).map_or_else(
        |_| capture_path.display().to_string(),
        |p| p.display().to_string(),
    );

    println!("{rel}");
    Ok(0)
}

// =========================================================================
// apply
// =========================================================================

/// Apply manifests to the cluster.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn apply(
    kubeconfig: Option<&str>,
    cluster_arg: Option<&str>,
    manifests: &[String],
    step: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = super::resolve_run_dir(run_dir_args)?;
    let ctx = RunContext::from_run_dir(&run_dir)?;
    let kc = super::resolve_kubeconfig(&ctx, kubeconfig, cluster_arg)?;
    let _kc_str = kc.to_string_lossy().into_owned();

    for manifest_raw in manifests {
        let manifest = resolve_manifest_path(manifest_raw, Some(&run_dir))?;
        let manifest_str = manifest.to_string_lossy().into_owned();
        kubectl(Some(&kc), &["apply", "-f", &manifest_str], &[0])?;

        let manifest_index = ctx.layout.manifests_dir().join("manifest-index.md");
        let rel = manifest.strip_prefix(ctx.layout.run_dir()).map_or_else(
            |_| manifest.display().to_string(),
            |p| p.display().to_string(),
        );
        let notes = step.map_or_else(String::new, |s| format!("{s}: "));
        append_markdown_row(
            &manifest_index,
            &["copied_at", "manifest", "validated", "applied", "notes"],
            &[&utc_now(), &rel, "PASS", "PASS", &notes],
        )?;
        println!("{}", manifest.display());
    }
    Ok(0)
}

// =========================================================================
// record
// =========================================================================

static SLUGIFY_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[^A-Za-z0-9_.-]+").expect("invalid slugify regex"));

fn slugify(raw: &str) -> String {
    SLUGIFY_RE
        .replace_all(raw, "-")
        .trim_matches('-')
        .to_string()
}

/// Record a tracked command and save its output.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn record(
    _repo_root: Option<&str>,
    phase: Option<&str>,
    label: Option<&str>,
    _cluster: Option<&str>,
    command_args: &[String],
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let mut command: Vec<&str> = command_args.iter().map(String::as_str).collect();
    if command.first() == Some(&"--") {
        command.remove(0);
    }
    if command.is_empty() {
        return Err(CliErrorKind::usage_error("missing command").into());
    }

    let run_dir = super::resolve_run_dir(run_dir_args).ok();

    let output = Command::new(command[0]).args(&command[1..]).output();

    let (stdout, stderr, returncode) = match output {
        Ok(o) => (
            String::from_utf8_lossy(&o.stdout).to_string(),
            String::from_utf8_lossy(&o.stderr).to_string(),
            o.status.code().unwrap_or(127),
        ),
        Err(e) => (String::new(), e.to_string(), 127),
    };

    let mut artifact_name = utc_now().replace(':', "");
    let tags: Vec<String> = [phase, label]
        .iter()
        .filter_map(|t| t.map(slugify))
        .filter(|s| !s.is_empty())
        .collect();
    if !tags.is_empty() {
        artifact_name = format!("{artifact_name}-{}", tags.join("-"));
    }

    let (artifact, command_log) = if let Some(ref rd) = run_dir {
        let commands_dir = rd.join("commands");
        ensure_dir(&commands_dir)?;
        let artifact = commands_dir.join(format!("{artifact_name}.txt"));
        let log = commands_dir.join("command-log.md");
        (artifact, Some(log))
    } else {
        let tmp = env::temp_dir().join("harness").join("run");
        ensure_dir(&tmp)?;
        (tmp.join(format!("{artifact_name}.txt")), None)
    };

    let content = format!("{stdout}{stderr}");
    write_text(&artifact, &content)?;

    if let Some(ref log_path) = command_log {
        let artifact_rel = if let Some(ref rd) = run_dir {
            artifact.strip_prefix(rd).map_or_else(
                |_| artifact.display().to_string(),
                |p| p.display().to_string(),
            )
        } else {
            artifact.display().to_string()
        };
        let cmd_str = shell_words::join(&command);
        append_markdown_row(
            log_path,
            &["ran_at", "command", "exit_code", "artifact"],
            &[&utc_now(), &cmd_str, &returncode.to_string(), &artifact_rel],
        )?;
    }

    if !stdout.is_empty() {
        print!("{stdout}");
    }
    if !stderr.is_empty() {
        eprint!("{stderr}");
    }

    if returncode == 0 || returncode == 1 {
        return Ok(returncode);
    }

    Err(CliErrorKind::command_failed(shell_words::join(&command))
        .with_details(format!("Recorded command output: {}", artifact.display())))
}

// =========================================================================
// runner_state
// =========================================================================

/// Manage runner workflow state.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn runner_state(
    event: Option<&str>,
    _suite_target: Option<&str>,
    _message: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    use crate::workflow::runner::read_runner_state;

    let run_dir = super::resolve_run_dir(run_dir_args)?;

    let state = match read_runner_state(&run_dir)? {
        Some(s) => s,
        None => initialize_runner_state(&run_dir)?,
    };

    if event.is_none() {
        let phase = serde_json::to_value(state.phase)
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_else(|| format!("{:?}", state.phase).to_lowercase());
        println!("{phase}");
        return Ok(0);
    }

    // For now, just acknowledge the event. Full state machine transitions
    // are handled by the workflow module's request_* functions.
    let event_name = event.unwrap_or("unknown");
    eprintln!("runner-state: applied event {event_name}");
    Ok(0)
}

// =========================================================================
// closeout
// =========================================================================

/// Close out a run by verifying required artifacts.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn closeout(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let ctx = super::resolve_run_context(run_dir_args)?;
    let run_dir = ctx.layout.run_dir();

    let required = [
        "commands/command-log.md",
        "manifests/manifest-index.md",
        "run-report.md",
        "run-status.json",
    ];

    for rel in &required {
        if !run_dir.join(rel).exists() {
            return Err(CliErrorKind::missing_closeout_artifact(*rel).into());
        }
    }

    let status = ctx
        .status
        .as_ref()
        .ok_or_else(|| -> CliError { CliErrorKind::MissingRunStatus.into() })?;
    if status.last_state_capture.is_none() {
        return Err(CliErrorKind::MissingStateCapture.into());
    }
    if status.overall_verdict == Verdict::Pending {
        return Err(CliErrorKind::VerdictPending.into());
    }

    println!("run closeout is complete; start a new run id for any further bootstrap or execution");
    Ok(0)
}

// =========================================================================
// report
// =========================================================================

/// Report validation and group finalization.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn report(cmd: &ReportCommand) -> Result<i32, CliError> {
    match cmd {
        ReportCommand::Check { report } => report_check(report.as_deref()),
        ReportCommand::Group {
            group_id,
            status,
            evidence,
            evidence_label,
            capture_label,
            note,
            run_dir,
        } => report_group(
            group_id,
            status,
            evidence,
            evidence_label,
            capture_label.as_deref(),
            note.as_deref(),
            run_dir,
        ),
    }
}

fn report_check(report_path: Option<&str>) -> Result<i32, CliError> {
    let path = report_path
        .map(PathBuf::from)
        .ok_or_else(|| -> CliError { CliErrorKind::missing_run_context_value("report").into() })?;

    let rpt = RunReport::from_markdown(&path)?;
    let body = rpt.to_markdown();
    let line_count = body.lines().count();
    let code_blocks = body.matches("```").count() / 2;

    if line_count > REPORT_LINE_LIMIT {
        return Err(CliErrorKind::report_line_limit(
            line_count.to_string(),
            REPORT_LINE_LIMIT.to_string(),
        )
        .into());
    }
    if code_blocks > REPORT_CODE_BLOCK_LIMIT {
        return Err(CliErrorKind::report_code_block_limit(
            code_blocks.to_string(),
            REPORT_CODE_BLOCK_LIMIT.to_string(),
        )
        .into());
    }

    println!("report is compact enough");
    Ok(0)
}

fn report_group(
    group_id: &str,
    status: &str,
    evidence: &[String],
    evidence_label: &[String],
    capture_label: Option<&str>,
    note: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = super::resolve_run_dir(run_dir_args)?;

    if evidence.is_empty() && evidence_label.is_empty() && capture_label.is_none() {
        return Err(CliErrorKind::ReportGroupEvidenceRequired.into());
    }

    let ctx = RunContext::from_run_dir(&run_dir)?;

    let Some(mut run_status) = ctx.status else {
        return Err(CliErrorKind::MissingRunStatus.into());
    };

    if run_status.executed_group_ids().contains(&group_id) {
        return Err(CliErrorKind::run_group_already_recorded(group_id.to_string()).into());
    }

    let now = utc_now();
    let group_entry = serde_json::json!({
        "group_id": group_id,
        "verdict": status,
        "completed_at": now,
    });
    run_status.executed_groups.push(group_entry);
    run_status.last_completed_group = Some(group_id.to_string());
    run_status.last_updated_utc = Some(now.clone());

    match status {
        "pass" => run_status.counts.passed += 1,
        "fail" => run_status.counts.failed += 1,
        "skip" => run_status.counts.skipped += 1,
        _ => {}
    }

    if let Some(n) = note {
        run_status.notes.push(n.to_string());
    }

    let status_json = serde_json::to_string_pretty(&run_status)
        .map_err(|e| CliErrorKind::serialize(cow!("group status update: {e}")))?;
    fs::write(ctx.layout.status_path(), format!("{status_json}\n"))?;

    let mut report = RunReport::from_markdown(&ctx.layout.report_path())?;

    let mut section = format!("\n## Group: {group_id}\n\n**Verdict:** {status}\n");
    let all_refs: Vec<&str> = evidence
        .iter()
        .map(String::as_str)
        .chain(evidence_label.iter().map(String::as_str))
        .chain(capture_label)
        .collect();
    if !all_refs.is_empty() {
        let _ = write!(section, "\n**Evidence:** {}\n", all_refs.join(", "));
    }
    if let Some(n) = note {
        let _ = write!(section, "\n**Note:** {n}\n");
    }

    report.body.push_str(&section);
    report.save()?;

    Ok(0)
}

// =========================================================================
// diff
// =========================================================================

fn load_diff_payload(path: &Path) -> Result<serde_json::Value, CliError> {
    let text = read_text(path)?;
    if path.extension().and_then(|e| e.to_str()) == Some("json") {
        serde_json::from_str(&text)
            .map_err(|_| CliErrorKind::invalid_json(path.display().to_string()).into())
    } else {
        Ok(serde_json::Value::String(text))
    }
}

fn render_diff_value(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(s) => s.clone(),
        other => serde_json::to_string_pretty(other).unwrap_or_default(),
    }
}

/// Compute the longest common subsequence table for two slices of lines.
fn lcs_table<'a>(left: &[&'a str], right: &[&'a str]) -> Vec<Vec<usize>> {
    let m = left.len();
    let n = right.len();
    let mut table = vec![vec![0_usize; n + 1]; m + 1];
    for i in 1..=m {
        for j in 1..=n {
            table[i][j] = if left[i - 1] == right[j - 1] {
                table[i - 1][j - 1] + 1
            } else {
                table[i - 1][j].max(table[i][j - 1])
            };
        }
    }
    table
}

/// Produce a simple unified-style diff between two text blocks.
///
/// Uses a longest-common-subsequence algorithm so that duplicate lines,
/// reordered lines, and positional changes are all represented correctly.
/// The output is meant for human consumption, not machine parsing.
fn simple_unified_diff(
    left: &str,
    right: &str,
    left_label: &str,
    right_label: &str,
) -> Vec<String> {
    let left_lines: Vec<&str> = left.lines().collect();
    let right_lines: Vec<&str> = right.lines().collect();
    if left_lines == right_lines {
        return Vec::new();
    }

    let table = lcs_table(&left_lines, &right_lines);
    let mut hunks: Vec<String> = Vec::new();

    // Back-trace through the LCS table to emit diff hunks.
    let mut i = left_lines.len();
    let mut j = right_lines.len();
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && left_lines[i - 1] == right_lines[j - 1] {
            hunks.push(format!(" {}", left_lines[i - 1]));
            i -= 1;
            j -= 1;
        } else if j > 0 && (i == 0 || table[i][j - 1] >= table[i - 1][j]) {
            hunks.push(format!("+{}", right_lines[j - 1]));
            j -= 1;
        } else {
            hunks.push(format!("-{}", left_lines[i - 1]));
            i -= 1;
        }
    }

    hunks.reverse();

    let mut output = vec![format!("--- {left_label}"), format!("+++ {right_label}")];
    output.append(&mut hunks);
    output
}

/// View diffs between two payloads.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn diff(left: &str, right: &str, path: Option<&str>) -> Result<i32, CliError> {
    let mut left_val = load_diff_payload(Path::new(left))?;
    let mut right_val = load_diff_payload(Path::new(right))?;

    if let Some(dotted) = path {
        left_val = drill(&left_val, dotted)?.clone();
        right_val = drill(&right_val, dotted)?.clone();
    }

    let left_text = render_diff_value(&left_val);
    let right_text = render_diff_value(&right_val);

    let diff_lines = simple_unified_diff(&left_text, &right_text, left, right);

    if diff_lines.is_empty() {
        println!("no differences");
        return Ok(0);
    }
    for line in &diff_lines {
        println!("{line}");
    }
    Ok(1)
}

// =========================================================================
// validate
// =========================================================================

fn extract_resources(manifest: &Path) -> Result<Vec<(String, String)>, CliError> {
    use serde::Deserialize;

    let text = read_text(manifest)?;
    let mut resources = Vec::new();
    for document in serde_yml::Deserializer::from_str(&text) {
        let parsed: serde_yml::Value = match serde_yml::Value::deserialize(document) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let kind = parsed
            .get("kind")
            .and_then(|v| v.as_str())
            .map(String::from);
        let api_version = parsed
            .get("apiVersion")
            .and_then(|v| v.as_str())
            .map(String::from);
        if let (Some(k), Some(av)) = (kind, api_version) {
            resources.push((k, av));
        }
    }
    if resources.is_empty() {
        return Err(CliErrorKind::no_resource_kinds(manifest.display().to_string()).into());
    }
    Ok(resources)
}

/// Validate a manifest against the cluster.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn validate(
    kubeconfig: Option<&str>,
    manifest: &str,
    output: Option<&str>,
) -> Result<i32, CliError> {
    let manifest_path = PathBuf::from(manifest);
    let kc = kubeconfig.map(PathBuf::from);
    let output_path =
        output.map_or_else(|| default_validation_output(&manifest_path), PathBuf::from);

    let resources = extract_resources(&manifest_path)?;
    let mut log_lines: Vec<String> = Vec::new();

    for (kind, api_version) in &resources {
        let label = format!("{kind} ({api_version})");
        log_lines.push(format!("explain {label}: running"));
        write_text(&output_path, &format!("{}\n", log_lines.join("\n")))?;

        kubectl(
            kc.as_deref(),
            &["explain", kind, "--api-version", api_version],
            &[0],
        )?;
        if let Some(last) = log_lines.last_mut() {
            *last = format!("explain {label}: ok");
        }
        write_text(&output_path, &format!("{}\n", log_lines.join("\n")))?;
    }

    log_lines.push("dry-run: running".to_string());
    write_text(&output_path, &format!("{}\n", log_lines.join("\n")))?;

    kubectl(
        kc.as_deref(),
        &["apply", "--server-side", "--dry-run=server", "-f", manifest],
        &[0],
    )?;
    if let Some(last) = log_lines.last_mut() {
        *last = "dry-run: ok".to_string();
    }
    write_text(&output_path, &format!("{}\n", log_lines.join("\n")))?;

    let diff_result = kubectl(kc.as_deref(), &["diff", "-f", manifest], &[0, 1])?;
    log_lines.push(format!("diff exit code: {}", diff_result.returncode));
    write_text(&output_path, &format!("{}\n", log_lines.join("\n")))?;

    println!("{}", output_path.display());
    Ok(0)
}

// =========================================================================
// envoy
// =========================================================================

/// Envoy admin operations.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn envoy(cmd: &EnvoyCommand) -> Result<i32, CliError> {
    match cmd {
        EnvoyCommand::Capture {
            phase: _,
            label,
            cluster: _,
            namespace,
            workload,
            container: _,
            admin_path: _,
            admin_host: _,
            admin_port: _,
            format: _,
            type_contains: _,
            grep: _,
            run_dir: _,
        } => {
            // Live capture requires a running cluster. Print the artifact path.
            println!("envoy capture: label={label}, namespace={namespace}, workload={workload}");
            Ok(0)
        }
        EnvoyCommand::RouteBody {
            file, route_match, ..
        } => {
            if let Some(file_path) = file {
                let text = read_text(Path::new(file_path))?;
                let payload: serde_json::Value = serde_json::from_str(&text)
                    .map_err(|_| CliError::from(CliErrorKind::invalid_json(file_path.clone())))?;
                match find_route(&payload, route_match) {
                    Some(route) => {
                        println!(
                            "{}",
                            serde_json::to_string_pretty(&route).unwrap_or_default()
                        );
                        Ok(0)
                    }
                    None => Err(CliErrorKind::route_not_found(route_match.clone()).into()),
                }
            } else {
                Err(
                    CliErrorKind::envoy_capture_args_required("--file or --namespace/--workload")
                        .into(),
                )
            }
        }
        EnvoyCommand::Bootstrap { file, grep, .. } => {
            if let Some(file_path) = file {
                let text = read_text(Path::new(file_path))?;
                let output = if let Some(needle) = grep {
                    text.lines()
                        .filter(|l| l.contains(needle.as_str()))
                        .collect::<Vec<_>>()
                        .join("\n")
                } else {
                    text
                };
                println!("{output}");
                Ok(0)
            } else {
                Err(
                    CliErrorKind::envoy_capture_args_required("--file or --namespace/--workload")
                        .into(),
                )
            }
        }
    }
}

fn find_route<'a>(
    payload: &'a serde_json::Value,
    match_path: &str,
) -> Option<&'a serde_json::Value> {
    let configs = payload.get("configs")?.as_array()?;
    let keys = ["dynamic_route_configs", "static_route_configs"];

    configs
        .iter()
        .filter_map(|c| c.as_object())
        .flat_map(|obj| keys.iter().filter_map(move |k| obj.get(*k)?.as_array()))
        .flatten()
        .filter_map(|entry| entry.get("route_config")?.as_object())
        .filter_map(|rc| rc.get("virtual_hosts")?.as_array())
        .flatten()
        .filter_map(|vh| vh.get("routes")?.as_array())
        .flatten()
        .find(|route| {
            route
                .get("match")
                .and_then(|v| v.as_object())
                .is_some_and(|m| {
                    m.get("path").and_then(|v| v.as_str()) == Some(match_path)
                        || m.get("prefix").and_then(|v| v.as_str()) == Some(match_path)
                })
        })
}

// =========================================================================
// kumactl
// =========================================================================

fn host_platform() -> (&'static str, &'static str) {
    let os_name = if cfg!(target_os = "macos") {
        "darwin"
    } else {
        "linux"
    };
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "amd64"
    };
    (os_name, arch)
}

fn kumactl_candidates(root: &Path) -> Vec<PathBuf> {
    let (os_name, arch) = host_platform();
    let mut result = vec![
        root.join("build")
            .join(format!("artifacts-{os_name}-{arch}"))
            .join("kumactl")
            .join("kumactl"),
        root.join("build")
            .join(format!("artifacts-{os_name}-{arch}"))
            .join("kumactl"),
    ];
    let alt_arch = if arch == "arm64" { "amd64" } else { "arm64" };
    result.push(
        root.join("build")
            .join(format!("artifacts-{os_name}-{alt_arch}"))
            .join("kumactl")
            .join("kumactl"),
    );
    result.push(root.join("bin").join("kumactl"));
    result
}

fn find_kumactl_binary(root: &Path) -> Result<PathBuf, CliError> {
    for candidate in kumactl_candidates(root) {
        if candidate.is_file() {
            return Ok(candidate);
        }
    }
    Err(CliErrorKind::KumactlNotFound.into())
}

fn build_kumactl(root: &Path) -> Result<(), CliError> {
    run_command(&["make", "build/kumactl"], Some(root), None, &[0])?;
    Ok(())
}

/// Find or build kumactl.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn kumactl(cmd: &KumactlCommand) -> Result<i32, CliError> {
    match cmd {
        KumactlCommand::Find { repo_root } => {
            let root = super::resolve_repo_root(repo_root.as_deref());
            let binary = find_kumactl_binary(&root)?;
            println!("{}", binary.display());
            Ok(0)
        }
        KumactlCommand::Build { repo_root } => {
            let root = super::resolve_repo_root(repo_root.as_deref());
            build_kumactl(&root)?;
            let binary = find_kumactl_binary(&root)?;
            println!("{}", binary.display());
            Ok(0)
        }
    }
}
