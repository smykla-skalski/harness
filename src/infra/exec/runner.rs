use std::collections::HashMap;
use std::iter;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

use tokio::io::{AsyncBufReadExt as _, AsyncRead, BufReader};
use tokio::process::Command as TokioCommand;
use tokio::sync::mpsc;
use tokio::time::sleep;
use tracing::info;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::environment::merge_env;

use super::{CommandResult, RUNTIME, filter_progress_line};

/// How long a subprocess can run without emitting a progress line before
/// we print a heartbeat message.
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

/// Run a command via `tokio::process::Command`, capturing stdout/stderr.
///
/// # Errors
/// Returns `CliError` if the exit code is not in `ok_exit_codes`.
pub(crate) fn run_command(
    args: &[&str],
    cwd: Option<&Path>,
    env: Option<&HashMap<String, String>>,
    ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    let (program, cmd_args) = args
        .split_first()
        .ok_or_else(|| CliError::from(CliErrorKind::EmptyCommandArgs))?;
    let cmd_string = command_string(args);
    let output = RUNTIME
        .block_on(async {
            build_tokio_command(program, cmd_args, cwd, env)
                .output()
                .await
        })
        .map_err(|error| {
            CliErrorKind::command_failed(cmd_string.clone()).with_details(error.to_string())
        })?;
    let result = build_result(args, output);
    if ok_exit_codes.contains(&result.returncode) {
        return Ok(result);
    }
    Err(CliErrorKind::command_failed(cmd_string).with_details(failure_details(&result)))
}

/// Run a command, surfacing progress while still capturing stdout/stderr.
///
/// # Errors
/// Returns `CliError` if the exit code is not in `ok_exit_codes`.
pub(crate) fn run_command_streaming(
    args: &[&str],
    cwd: Option<&Path>,
    env: Option<&HashMap<String, String>>,
    ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    let (program, cmd_args) = args
        .split_first()
        .ok_or_else(|| CliError::from(CliErrorKind::EmptyCommandArgs))?;
    let cmd_string = command_string(args);
    let heartbeat_label = describe_command(args);
    let args_owned: Vec<String> = args.iter().map(|segment| (*segment).to_string()).collect();

    let result = RUNTIME.block_on(async move {
        let mut cmd = build_tokio_command(program, cmd_args, cwd, env);
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|error| {
            CliErrorKind::command_failed(cmd_string.clone()).with_details(error.to_string())
        })?;
        let started_at = Instant::now();
        info!("{heartbeat_label} started");

        let heartbeat_started_at = started_at;
        let heartbeat_task = tokio::spawn(async move {
            loop {
                sleep(HEARTBEAT_INTERVAL).await;
                info!(
                    "{} still running ({}s elapsed)",
                    heartbeat_label,
                    heartbeat_started_at.elapsed().as_secs()
                );
            }
        });

        let (progress_tx, mut progress_rx) = mpsc::unbounded_channel();
        let stdout_task = tokio::spawn(capture_stream(child.stdout.take(), progress_tx.clone()));
        let stderr_task = tokio::spawn(capture_stream(child.stderr.take(), progress_tx));
        let progress_task = tokio::spawn(async move {
            while let Some(message) = progress_rx.recv().await {
                info!(progress = %message, "command progress");
            }
        });

        let status = child.wait().await.map_err(|error| {
            CliErrorKind::command_failed(cmd_string.clone()).with_details(error.to_string())
        })?;

        heartbeat_task.abort();
        heartbeat_task.await.ok();
        let stdout = stdout_task.await.unwrap_or_default();
        let stderr = stderr_task.await.unwrap_or_default();
        progress_task.await.ok();
        info!(
            "{} completed in {}s",
            describe_command_from_owned_args(&args_owned),
            started_at.elapsed().as_secs()
        );

        Ok::<CommandResult, CliError>(CommandResult {
            args: args_owned,
            returncode: status.code().unwrap_or(-1),
            stdout,
            stderr,
        })
    })?;

    if ok_exit_codes.contains(&result.returncode) {
        return Ok(result);
    }
    Err(CliErrorKind::command_failed(command_string(args)).with_details(failure_details(&result)))
}

/// Run a command with stdout and stderr inherited by the terminal.
///
/// # Errors
/// Returns `CliError` if the command fails to start or exits with a bad code.
pub(crate) fn run_command_inherited(args: &[&str], ok_exit_codes: &[i32]) -> Result<i32, CliError> {
    let (program, cmd_args) = args
        .split_first()
        .ok_or_else(|| CliError::from(CliErrorKind::EmptyCommandArgs))?;
    let merged = merge_env(iter::empty());
    let status = Command::new(program)
        .args(cmd_args)
        .envs(&merged)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| {
            CliErrorKind::command_failed(command_string(args)).with_details(error.to_string())
        })?;
    let code = status.code().unwrap_or(-1);
    if ok_exit_codes.contains(&code) {
        return Ok(code);
    }
    Err(CliErrorKind::command_failed(command_string(args))
        .with_details(format!("exit code {code}")))
}

fn build_tokio_command(
    program: &str,
    cmd_args: &[&str],
    cwd: Option<&Path>,
    env: Option<&HashMap<String, String>>,
) -> TokioCommand {
    let merged = merge_env(env.into_iter().flat_map(|vars| vars.iter()));
    let mut cmd = TokioCommand::new(program);
    cmd.args(cmd_args).envs(&merged);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    cmd
}

fn build_result(args: &[&str], output: Output) -> CommandResult {
    let Output {
        status,
        stdout,
        stderr,
    } = output;
    CommandResult {
        args: args.iter().map(|segment| (*segment).to_string()).collect(),
        returncode: status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&stdout).into_owned(),
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
    }
}

fn failure_details(result: &CommandResult) -> String {
    let stderr = result.stderr.trim();
    if !stderr.is_empty() {
        return stderr.to_string();
    }
    let stdout = result.stdout.trim();
    if stdout.is_empty() {
        "external command failed".to_string()
    } else {
        stdout.to_string()
    }
}

fn command_string(args: &[&str]) -> String {
    args.join(" ")
}

pub(super) fn describe_command(args: &[&str]) -> String {
    if args.first() == Some(&"make")
        && let Some(target) = args.get(1)
    {
        return (*target).to_string();
    }
    if args.len() >= 2 && args[0] == "docker" && args[1] == "compose" {
        let compose_subcommands = ["up", "down", "start", "stop", "build", "pull", "logs"];
        let subcommand = args
            .iter()
            .skip(2)
            .find(|arg| compose_subcommands.contains(arg));
        return format!("compose {}", subcommand.unwrap_or(&"operation"));
    }
    args.iter().take(2).copied().collect::<Vec<_>>().join(" ")
}

async fn capture_stream<T>(pipe: Option<T>, progress_tx: mpsc::UnboundedSender<String>) -> String
where
    T: AsyncRead + Unpin,
{
    let Some(pipe) = pipe else {
        return String::new();
    };

    capture_stream_from_pipe(pipe, progress_tx).await
}

async fn capture_stream_from_pipe<T>(pipe: T, progress_tx: mpsc::UnboundedSender<String>) -> String
where
    T: AsyncRead + Unpin,
{
    let mut reader = BufReader::new(pipe);
    let mut chunk = Vec::new();
    let mut captured = String::new();
    while let Some(text) = read_stream_chunk(&mut reader, &mut chunk).await {
        send_progress_message(&progress_tx, &text);
        captured.push_str(&text);
    }
    captured
}

fn describe_command_from_owned_args(args: &[String]) -> String {
    let borrowed = args.iter().map(String::as_str).collect::<Vec<_>>();
    describe_command(&borrowed)
}

async fn read_stream_chunk<T>(reader: &mut BufReader<T>, chunk: &mut Vec<u8>) -> Option<String>
where
    T: AsyncRead + Unpin,
{
    chunk.clear();
    let bytes = reader.read_until(b'\n', chunk).await.unwrap_or(0);
    if bytes == 0 {
        return None;
    }
    Some(String::from_utf8_lossy(chunk).into_owned())
}

fn stream_progress_message(text: &str) -> Option<String> {
    let trimmed = text.trim_end_matches(['\n', '\r']);
    filter_progress_line(trimmed)
}

fn send_progress_message(progress_tx: &mpsc::UnboundedSender<String>, text: &str) {
    if let Some(message) = stream_progress_message(text) {
        let _ = progress_tx.send(message);
    }
}
