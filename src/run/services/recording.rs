use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

use regex::Regex;
use tracing::warn;

use crate::core_defs::{shorten_path, utc_now};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::cli::primary_kumactl_dir;
use crate::infra::io::{ensure_dir, write_text};
use crate::platform::cluster::Platform;
use crate::run::context::RunLayout;
use crate::run::workflow::{RunnerPhase, read_runner_state};

use super::RunServices;

#[derive(Debug, Clone)]
pub struct RecordCommandRequest<'a> {
    pub phase: Option<&'a str>,
    pub label: Option<&'a str>,
    pub gid: Option<&'a str>,
    pub cluster: Option<&'a str>,
    pub command_args: &'a [String],
    pub run_dir: Option<&'a Path>,
}

#[derive(Debug, Clone)]
pub struct RecordedCommandResult {
    pub artifact: PathBuf,
    pub stdout: String,
}

static SLUGIFY_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[^A-Za-z0-9_.-]+").expect("invalid slugify regex"));

/// Execute a command, persist its artifact, and append the command log when a run is active.
///
/// # Errors
/// Returns `CliError` on validation, IO, or wrapped command failure.
pub fn record_command(request: &RecordCommandRequest<'_>) -> Result<RecordedCommandResult, CliError> {
    let mut command: Vec<&str> = request.command_args.iter().map(String::as_str).collect();
    if command.first() == Some(&"--") {
        command.remove(0);
    }
    if command.is_empty() {
        return Err(CliErrorKind::usage_error("missing command").into());
    }

    let workflow_phase = resolve_workflow_phase(request.run_dir)?;
    validate_gid_usage(&workflow_phase, request.gid, request.run_dir.is_some())?;

    let (stdout, stderr, return_code) = execute_command(&command, request.run_dir, request.cluster);
    let artifact_name = build_artifact_name(request.phase, request.label);
    let layout = request.run_dir.map(RunLayout::from_run_dir);
    let artifact = resolve_artifact_path(layout.as_ref(), &artifact_name)?;
    let content =
        format!("exit code: {return_code}\n--- STDOUT ---\n{stdout}\n--- STDERR ---\n{stderr}");
    write_text(&artifact, &content)?;

    if let Some(ref layout) = layout {
        let artifact_rel = layout.relative_path(&artifact);
        let command_text = shell_words::join(&command);
        let group_id = log_group_id(&workflow_phase, request.gid);
        layout.append_command_log(
            &utc_now(),
            &workflow_phase,
            group_id,
            &command_text,
            &return_code.to_string(),
            artifact_rel.as_ref(),
        )?;
    }

    if return_code == 0 {
        return Ok(RecordedCommandResult { artifact, stdout });
    }

    Err(
        CliErrorKind::command_failed(shell_words::join(&command)).with_details(format!(
            "Recorded command output: {}",
            shorten_path(&artifact)
        )),
    )
}

fn slugify(raw: &str) -> String {
    SLUGIFY_RE
        .replace_all(raw, "-")
        .trim_matches('-')
        .to_string()
}

fn execute_command(
    command: &[&str],
    run_dir: Option<&Path>,
    cluster: Option<&str>,
) -> (String, String, i32) {
    let mut process = Command::new(command[0]);
    process.args(&command[1..]);
    if let Some(run_dir) = run_dir {
        inject_run_env(&mut process, run_dir, cluster);
    }
    match process.output() {
        Ok(output) => (
            String::from_utf8_lossy(&output.stdout).to_string(),
            String::from_utf8_lossy(&output.stderr).to_string(),
            output.status.code().unwrap_or(127),
        ),
        Err(error) => (String::new(), error.to_string(), 127),
    }
}

fn inject_run_env(cmd: &mut Command, run_dir: &Path, cluster: Option<&str>) {
    let services = match RunServices::from_run_dir(run_dir) {
        Ok(services) => services,
        Err(error) => {
            warn!(%error, "failed to load run context");
            return;
        }
    };
    let context = services.context();
    let is_universal = context
        .cluster
        .as_ref()
        .map(|spec| spec.platform)
        .is_some_and(|platform| platform == Platform::Universal);
    inject_kubeconfig_env(cmd, &services, is_universal, cluster);
    inject_repo_env(cmd, &context.metadata.repo_root);
}

fn inject_kubeconfig_env(
    cmd: &mut Command,
    services: &RunServices,
    is_universal: bool,
    cluster: Option<&str>,
) {
    if is_universal {
        return;
    }
    match services.resolve_kubeconfig(None, cluster) {
        Ok(kubeconfig) => {
            cmd.env("KUBECONFIG", kubeconfig.as_ref());
        }
        Err(error) => warn!(%error, "failed to resolve kubeconfig"),
    }
}

fn inject_repo_env(cmd: &mut Command, repo_root: &str) {
    if repo_root.is_empty() {
        return;
    }
    cmd.env("REPO_ROOT", repo_root);
    let kumactl_dir = primary_kumactl_dir(Path::new(repo_root));
    if kumactl_dir.is_dir() {
        let current_path = env::var("PATH").unwrap_or_default();
        cmd.env("PATH", format!("{}:{current_path}", kumactl_dir.display()));
    }
}

fn build_artifact_name(phase: Option<&str>, label: Option<&str>) -> String {
    let mut name = utc_now().replace(':', "");
    let tags: Vec<String> = [phase, label]
        .iter()
        .filter_map(|tag| tag.map(slugify))
        .filter(|tag| !tag.is_empty())
        .collect();
    if !tags.is_empty() {
        name = format!("{name}-{}", tags.join("-"));
    }
    name
}

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
