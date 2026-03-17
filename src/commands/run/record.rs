use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

use clap::Args;
use regex::Regex;

use crate::commands::{RunDirArgs, resolve_run_dir};
use crate::context::RunLayout;
use crate::core_defs::{shorten_path, utc_now};
use crate::errors::{CliError, CliErrorKind};
use crate::io::{ensure_dir, write_text};
use crate::workflow::runner::{RunnerPhase, read_runner_state};

use super::shared::inject_run_env;

/// Arguments for `harness record`.
#[derive(Debug, Clone, Args)]
pub struct RecordArgs {
    /// Repo root for local command resolution.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Optional phase tag for the command artifact name.
    #[arg(long)]
    pub phase: Option<String>,
    /// Optional label tag for the command artifact name.
    #[arg(long)]
    pub label: Option<String>,
    /// Execution-phase group ID for tracked commands.
    #[arg(long)]
    pub gid: Option<String>,
    /// Tracked cluster member name for kubectl commands.
    #[arg(long)]
    pub cluster: Option<String>,
    /// Command to execute; prefix with -- to stop flag parsing.
    #[arg(allow_hyphen_values = true)]
    pub command: Vec<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

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
    gid: Option<&str>,
    cluster: Option<&str>,
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

    let run_dir = resolve_optional_run_dir(run_dir_args)?;
    let workflow_phase = resolve_workflow_phase(run_dir.as_deref())?;
    validate_gid_usage(&workflow_phase, gid, run_dir.is_some())?;

    let (stdout, stderr, returncode) = execute_command(&command, run_dir.as_deref(), cluster);

    let artifact_name = build_artifact_name(phase, label);
    let layout = run_dir.as_deref().map(RunLayout::from_run_dir);
    let artifact = resolve_artifact_path(layout.as_ref(), &artifact_name)?;

    let content =
        format!("exit code: {returncode}\n--- STDOUT ---\n{stdout}\n--- STDERR ---\n{stderr}");
    write_text(&artifact, &content)?;

    if let Some(ref layout) = layout {
        let artifact_rel = layout.relative_path(&artifact);
        let cmd_str = shell_words::join(&command);
        let group_id = log_group_id(&workflow_phase, gid);
        layout.append_command_log(
            &utc_now(),
            &workflow_phase,
            group_id,
            &cmd_str,
            &returncode.to_string(),
            artifact_rel.as_ref(),
        )?;
    }

    if !stdout.is_empty() {
        print!("{stdout}");
    }
    // stderr is saved to the artifact file but not printed to the terminal -
    // wrapped commands often emit noisy warnings (e.g. control plane not
    // reachable yet) that confuse the user.

    if returncode == 0 {
        return Ok(returncode);
    }

    Err(
        CliErrorKind::command_failed(shell_words::join(&command)).with_details(format!(
            "Recorded command output: {}",
            shorten_path(&artifact)
        )),
    )
}

/// Resolve the run directory, treating `MissingRunPointer` as `None`.
fn resolve_optional_run_dir(run_dir_args: &RunDirArgs) -> Result<Option<PathBuf>, CliError> {
    let implicit_lookup = run_dir_args.run_dir.is_none()
        && run_dir_args.run_id.is_none()
        && run_dir_args.run_root.is_none();
    match resolve_run_dir(run_dir_args) {
        Ok(rd) => Ok(Some(rd)),
        Err(e) if matches!(e.kind(), CliErrorKind::MissingRunPointer) => Ok(None),
        Err(e) if implicit_lookup && e.code() == "KSRCLI014" => Ok(None),
        Err(e) => Err(e),
    }
}

/// Run the command and return (stdout, stderr, exit code).
fn execute_command(
    command: &[&str],
    run_dir: Option<&Path>,
    cluster: Option<&str>,
) -> (String, String, i32) {
    let mut process = Command::new(command[0]);
    process.args(&command[1..]);
    if let Some(rd) = run_dir {
        inject_run_env(&mut process, rd, cluster);
    }
    match process.output() {
        Ok(o) => (
            String::from_utf8_lossy(&o.stdout).to_string(),
            String::from_utf8_lossy(&o.stderr).to_string(),
            o.status.code().unwrap_or(127),
        ),
        Err(e) => (String::new(), e.to_string(), 127),
    }
}

/// Build the artifact file name from timestamp and optional tags.
fn build_artifact_name(phase: Option<&str>, label: Option<&str>) -> String {
    let mut name = utc_now().replace(':', "");
    let tags: Vec<String> = [phase, label]
        .iter()
        .filter_map(|t| t.map(slugify))
        .filter(|s| !s.is_empty())
        .collect();
    if !tags.is_empty() {
        name = format!("{name}-{}", tags.join("-"));
    }
    name
}

/// Resolve the artifact file path, creating the parent directory.
fn resolve_artifact_path(
    layout: Option<&RunLayout>,
    artifact_name: &str,
) -> Result<PathBuf, CliError> {
    let (dir, file) = if let Some(layout) = layout {
        (layout.commands_dir(), format!("{artifact_name}.txt"))
    } else {
        (
            env::temp_dir().join("harness").join("run"),
            format!("{artifact_name}.txt"),
        )
    };
    ensure_dir(&dir)?;
    Ok(dir.join(file))
}

fn resolve_workflow_phase(run_dir: Option<&Path>) -> Result<String, CliError> {
    let Some(run_dir) = run_dir else {
        return Ok("-".to_string());
    };
    Ok(read_runner_state(run_dir)?
        .map_or_else(|| "-".to_string(), |state| state.phase().to_string()))
}

fn validate_gid_usage(
    workflow_phase: &str,
    gid: Option<&str>,
    has_run_dir: bool,
) -> Result<(), CliError> {
    if gid.is_some() && !has_run_dir {
        return Err(
            CliErrorKind::usage_error("--gid requires an active run context".to_string()).into(),
        );
    }

    if workflow_phase == RunnerPhase::Execution.to_string() {
        if gid.is_none() {
            return Err(CliErrorKind::usage_error(
                "--gid is required when recording commands during the execution phase".to_string(),
            )
            .into());
        }
        return Ok(());
    }

    if gid.is_some() {
        return Err(CliErrorKind::usage_error(
            "--gid is only allowed when the active run is in the execution phase".to_string(),
        )
        .into());
    }

    Ok(())
}

fn log_group_id<'a>(workflow_phase: &str, gid: Option<&'a str>) -> &'a str {
    if workflow_phase == RunnerPhase::Execution.to_string() {
        gid.unwrap_or("-")
    } else {
        "-"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_gid_usage_requires_gid_for_execution_phase() {
        let error = validate_gid_usage("execution", None, true).unwrap_err();
        assert!(error.message().contains("--gid is required"));
    }

    #[test]
    fn validate_gid_usage_rejects_gid_outside_execution_phase() {
        let error = validate_gid_usage("bootstrap", Some("g01"), true).unwrap_err();
        assert!(error.message().contains("only allowed"));
    }

    #[test]
    fn validate_gid_usage_allows_execution_with_gid() {
        validate_gid_usage("execution", Some("g01"), true).unwrap();
    }

    #[test]
    fn log_group_id_uses_dash_outside_execution_phase() {
        assert_eq!(log_group_id("closeout", Some("g01")), "-");
    }
}
