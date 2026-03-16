use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

use regex::Regex;

use crate::cli::RunDirArgs;
use crate::cluster::Platform;
use crate::commands::{resolve_kubeconfig, resolve_run_dir};
use crate::context::{RunContext, RunLayout};
use crate::core_defs::{host_platform, shorten_path, utc_now};
use crate::errors::{CliError, CliErrorKind};
use crate::io::{ensure_dir, write_text};
use crate::workflow::runner::{RunnerPhase, read_runner_state};

static SLUGIFY_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[^A-Za-z0-9_.-]+").expect("invalid slugify regex"));

fn slugify(raw: &str) -> String {
    SLUGIFY_RE
        .replace_all(raw, "-")
        .trim_matches('-')
        .to_string()
}

/// Inject `KUBECONFIG` and `REPO_ROOT` from the persisted run context so
/// kubectl hits the local k3d cluster and kumactl resolves to the
/// worktree build, not whatever is on the default PATH.
///
/// Best-effort: logs warnings on failure instead of propagating errors
/// because record works in detached mode without a full run context.
fn inject_run_env(cmd: &mut Command, run_dir: &Path, cluster: Option<&str>) {
    let ctx = match RunContext::from_run_dir(run_dir) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("warning: failed to load run context: {e}");
            return;
        }
    };
    let is_universal = ctx
        .cluster
        .as_ref()
        .is_some_and(|spec| spec.platform == Platform::Universal);
    if !is_universal {
        match resolve_kubeconfig(&ctx, None, cluster) {
            Ok(kubeconfig) => {
                cmd.env("KUBECONFIG", kubeconfig);
            }
            Err(e) => eprintln!("warning: failed to resolve kubeconfig: {e}"),
        }
    }
    let repo_root = &ctx.metadata.repo_root;
    if !repo_root.is_empty() {
        cmd.env("REPO_ROOT", repo_root);
        let (os_name, arch) = host_platform();
        let kumactl_dir = format!("{repo_root}/build/artifacts-{os_name}-{arch}/kumactl");
        if Path::new(&kumactl_dir).is_dir() {
            let current_path = env::var("PATH").unwrap_or_default();
            cmd.env("PATH", format!("{kumactl_dir}:{current_path}"));
        }
    }
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

    let run_dir = match resolve_run_dir(run_dir_args) {
        Ok(rd) => Some(rd),
        Err(e) => {
            if matches!(e.kind(), CliErrorKind::MissingRunPointer) {
                None
            } else {
                return Err(e);
            }
        }
    };
    let workflow_phase = resolve_workflow_phase(run_dir.as_deref())?;
    validate_gid_usage(&workflow_phase, gid, run_dir.is_some())?;

    let mut cmd = Command::new(command[0]);
    cmd.args(&command[1..]);
    if let Some(ref rd) = run_dir {
        inject_run_env(&mut cmd, rd, cluster);
    }
    let output = cmd.output();

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

    let layout = run_dir.as_deref().map(RunLayout::from_run_dir);

    let artifact: PathBuf = if let Some(ref layout) = layout {
        let commands_dir = layout.commands_dir();
        ensure_dir(&commands_dir)?;
        commands_dir.join(format!("{artifact_name}.txt"))
    } else {
        let tmp = env::temp_dir().join("harness").join("run");
        ensure_dir(&tmp)?;
        tmp.join(format!("{artifact_name}.txt"))
    };

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
            &artifact_rel,
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

fn resolve_workflow_phase(run_dir: Option<&Path>) -> Result<String, CliError> {
    let Some(run_dir) = run_dir else {
        return Ok("-".to_string());
    };
    Ok(
        read_runner_state(run_dir)?
            .map_or_else(|| "-".to_string(), |state| state.phase.to_string()),
    )
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
