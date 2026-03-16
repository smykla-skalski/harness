use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

use regex::Regex;

use crate::cli::RunDirArgs;
use crate::commands::{resolve_kubeconfig, resolve_run_dir};
use crate::context::RunContext;
use crate::core_defs::{host_platform, shorten_path, utc_now};
use crate::errors::{CliError, CliErrorKind};
use crate::io::{append_markdown_row, ensure_dir, write_text};

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

    let run_dir = resolve_run_dir(run_dir_args).ok();

    // Inject KUBECONFIG and REPO_ROOT from the persisted run context so
    // kubectl hits the local k3d cluster and kumactl resolves to the
    // worktree build, not whatever is on the default PATH.
    let mut cmd = Command::new(command[0]);
    cmd.args(&command[1..]);
    if let Some(ref rd) = run_dir {
        let ctx = RunContext::from_run_dir(rd).ok();
        if let Some(ref c) = ctx {
            if let Ok(kc) = resolve_kubeconfig(c, None, cluster) {
                cmd.env("KUBECONFIG", kc);
            }
            let repo_root = &c.metadata.repo_root;
            if !repo_root.is_empty() {
                cmd.env("REPO_ROOT", repo_root);
                // Prepend kumactl build artifacts to PATH
                let (os_name, arch) = host_platform();
                let kumactl_dir = format!("{repo_root}/build/artifacts-{os_name}-{arch}/kumactl");
                if Path::new(&kumactl_dir).is_dir() {
                    let current_path = env::var("PATH").unwrap_or_default();
                    cmd.env("PATH", format!("{kumactl_dir}:{current_path}"));
                }
            }
        }
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

    let (artifact, command_log): (PathBuf, Option<PathBuf>) = if let Some(ref rd) = run_dir {
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
    // stderr is saved to the artifact file but not printed to the terminal -
    // wrapped commands often emit noisy warnings (e.g. control plane not
    // reachable yet) that confuse the user.

    if returncode == 0 || returncode == 1 {
        return Ok(returncode);
    }

    Err(
        CliErrorKind::command_failed(shell_words::join(&command)).with_details(format!(
            "Recorded command output: {}",
            shorten_path(&artifact)
        )),
    )
}
