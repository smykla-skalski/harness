use std::env;
use std::process::Command;
use std::sync::LazyLock;

use regex::Regex;

use crate::cli::RunDirArgs;
use crate::core_defs::utc_now;
use crate::errors::{self, CliError};
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
pub fn execute(
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
        return Err(CliError {
            code: "USAGE".into(),
            message: "missing command".to_string(),
            exit_code: 1,
            hint: None,
            details: None,
        });
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
        ensure_dir(&commands_dir).map_err(|e| CliError {
            code: "IO".into(),
            message: format!("failed to create directory {}: {e}", commands_dir.display()),
            exit_code: 1,
            hint: None,
            details: None,
        })?;
        let artifact = commands_dir.join(format!("{artifact_name}.txt"));
        let log = commands_dir.join("command-log.md");
        (artifact, Some(log))
    } else {
        let tmp = env::temp_dir().join("harness").join("run");
        ensure_dir(&tmp).map_err(|e| CliError {
            code: "IO".into(),
            message: format!("failed to create directory {}: {e}", tmp.display()),
            exit_code: 1,
            hint: None,
            details: None,
        })?;
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

    Err(errors::cli_err_with_details(
        &errors::COMMAND_FAILED,
        &[("command", &shell_words::join(&command))],
        &format!("Recorded command output: {}", artifact.display()),
    ))
}
