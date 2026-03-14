use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use crate::core_defs::{CommandResult, merge_env};
use crate::errors::{self, COMMAND_FAILED, CliError};

/// Run a command via `std::process::Command`, capturing stdout/stderr.
///
/// # Errors
/// Returns `CliError` if the exit code is not in `ok_exit_codes`.
pub fn run_command(
    args: &[&str],
    cwd: Option<&Path>,
    env: Option<&HashMap<String, String>>,
    ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    let (program, cmd_args) = args.split_first().expect("args must not be empty");
    let merged = merge_env(env);
    let mut cmd = Command::new(program);
    cmd.args(cmd_args).envs(&merged);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    let output = cmd.output().map_err(|e| {
        errors::cli_err_with_details(
            &COMMAND_FAILED,
            &[("command", &args.join(" "))],
            &e.to_string(),
        )
    })?;
    let returncode = output.status.code().unwrap_or(-1);
    let result = CommandResult {
        args: args.iter().map(|s| (*s).to_string()).collect(),
        returncode,
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    };
    if ok_exit_codes.contains(&returncode) {
        return Ok(result);
    }
    let details = if result.stderr.trim().is_empty() {
        if result.stdout.trim().is_empty() {
            "external command failed".to_string()
        } else {
            result.stdout.trim().to_string()
        }
    } else {
        result.stderr.trim().to_string()
    };
    Err(errors::cli_err_with_details(
        &COMMAND_FAILED,
        &[("command", &args.join(" "))],
        &details,
    ))
}

/// Run kubectl with optional kubeconfig.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn kubectl(
    kubeconfig: Option<&Path>,
    args: &[&str],
    ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    let mut command: Vec<&str> = vec!["kubectl"];
    let kc_str;
    if let Some(kc) = kubeconfig {
        kc_str = kc.to_string_lossy().into_owned();
        command.push("--kubeconfig");
        command.push(&kc_str);
    }
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}

/// Run k3d.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn k3d(args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, CliError> {
    let mut command: Vec<&str> = vec!["k3d"];
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}

/// Run docker.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker(args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, CliError> {
    let mut command: Vec<&str> = vec!["docker"];
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}

/// Check if a k3d cluster exists.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn cluster_exists(name: &str) -> Result<bool, CliError> {
    let result = k3d(&["cluster", "list", "--no-headers"], &[0])?;
    Ok(result
        .stdout
        .lines()
        .any(|line| line.split_whitespace().next() == Some(name)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_echo_captures_stdout() {
        let result = run_command(&["echo", "hello"], None, None, &[0]).unwrap();
        assert_eq!(result.stdout.trim(), "hello");
        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn run_command_rejects_bad_exit_code() {
        let err = run_command(&["false"], None, None, &[0]).unwrap_err();
        assert!(err.message.contains("command failed"));
    }

    #[test]
    fn run_command_accepts_custom_ok_codes() {
        let result = run_command(&["false"], None, None, &[0, 1]).unwrap();
        assert_eq!(result.returncode, 1);
    }

    #[test]
    fn run_command_with_cwd() {
        let result = run_command(&["pwd"], Some(Path::new("/tmp")), None, &[0]).unwrap();
        // /tmp may resolve to /private/tmp on macOS
        assert!(result.stdout.trim().ends_with("/tmp"));
    }

    #[test]
    fn run_command_with_env() {
        let mut env = HashMap::new();
        env.insert("TEST_VAR_XYZ".to_string(), "harness_test".to_string());
        let result =
            run_command(&["sh", "-c", "echo $TEST_VAR_XYZ"], None, Some(&env), &[0]).unwrap();
        assert_eq!(result.stdout.trim(), "harness_test");
    }
}
