#![deny(unsafe_code)]

use std::env;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

mod trusted;

pub use trusted::{exec_trusted_worker, resolve_trusted_worker};

/// Explicit worker-directory override used by development and integration tests.
pub const WORKER_DIR_ENV: &str = "HARNESS_WORKER_DIR";

/// Error returned while resolving or replacing the current process with a worker.
#[derive(Debug)]
pub struct WorkerError {
    message: String,
}

impl WorkerError {
    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }

    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for WorkerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.message.fmt(formatter)
    }
}

impl std::error::Error for WorkerError {}

/// Resolve an owned Harness worker beside the running executable.
///
/// Production resolution never searches `PATH`. An explicit development override is
/// accepted only when the selected worker reports the expected workspace version.
///
/// # Errors
/// Returns an error when the current executable, worker, or version probe is invalid.
pub fn resolve_worker(name: &str, expected_version: &str) -> Result<PathBuf, WorkerError> {
    validate_worker_name(name)?;
    if let Some(directory) = env::var_os(WORKER_DIR_ENV).filter(|value| !value.is_empty()) {
        let worker = PathBuf::from(directory).join(name);
        validate_override(&worker, name, expected_version)?;
        return Ok(worker);
    }

    let executable = env::current_exe()
        .map_err(|error| WorkerError::new(format!("resolve current executable: {error}")))?;
    resolve_sibling_worker(&executable, name)
}

fn resolve_sibling_worker(executable: &Path, name: &str) -> Result<PathBuf, WorkerError> {
    let executable = executable.canonicalize().map_err(|error| {
        WorkerError::new(format!(
            "resolve current executable at {}: {error}",
            executable.display()
        ))
    })?;
    let directory = executable.parent().ok_or_else(|| {
        WorkerError::new(format!(
            "current executable has no parent directory: {}",
            executable.display()
        ))
    })?;
    let worker = directory.join(name);
    validate_regular_worker(&worker, name)?;
    Ok(worker)
}

/// Replace the current process with a sibling worker while preserving its exit and
/// signal behavior.
///
/// # Errors
/// Returns an error only when worker resolution or process replacement fails.
pub fn exec_worker<I, S>(name: &str, expected_version: &str, args: I) -> Result<i32, WorkerError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let worker = resolve_worker(name, expected_version)?;
    let mut command = Command::new(&worker);
    command.args(args);
    exec(&mut command, &worker)
}

/// Return the arguments following a public `harness <route>` prefix.
///
/// The root CLI applies its global `--delay` before delegation, so that option is
/// removed from the worker argument vector to prevent a second delay.
///
/// # Errors
/// Returns an error when the live argument vector does not match the parsed route.
pub fn routed_args(route: &str) -> Result<Vec<OsString>, WorkerError> {
    routed_args_from(env::args_os(), route)
}

fn routed_args_from<I, S>(args: I, route: &str) -> Result<Vec<OsString>, WorkerError>
where
    I: IntoIterator<Item = S>,
    S: Into<OsString>,
{
    let mut args = args.into_iter().map(Into::into);
    let _program = args.next();
    for argument in args.by_ref() {
        if argument == OsStr::new(route) {
            return strip_root_delay(args);
        }
    }
    Err(WorkerError::new(format!(
        "missing harness route while delegating to {route}"
    )))
}

fn strip_root_delay<I>(args: I) -> Result<Vec<OsString>, WorkerError>
where
    I: IntoIterator<Item = OsString>,
{
    let mut args = args.into_iter();
    let mut worker_args = Vec::new();
    let mut options_ended = false;

    while let Some(argument) = args.next() {
        if options_ended {
            worker_args.push(argument);
        } else if argument == OsStr::new("--") {
            options_ended = true;
            worker_args.push(argument);
        } else if argument == OsStr::new("--delay") {
            args.next().ok_or_else(|| {
                WorkerError::new("missing value for root --delay while delegating to worker")
            })?;
        } else if argument
            .to_str()
            .is_some_and(|value| value.starts_with("--delay="))
        {
            // The root process already applied this delay.
        } else {
            worker_args.push(argument);
        }
    }

    Ok(worker_args)
}

fn validate_worker_name(name: &str) -> Result<(), WorkerError> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.contains(std::path::MAIN_SEPARATOR)
    {
        return Err(WorkerError::new(format!(
            "invalid Harness worker name: {name:?}"
        )));
    }
    Ok(())
}

fn validate_regular_worker(path: &Path, name: &str) -> Result<(), WorkerError> {
    let metadata = path.metadata().map_err(|error| {
        WorkerError::new(format!(
            "resolve Harness worker {name} at {}: {error}",
            path.display()
        ))
    })?;
    if !metadata.is_file() {
        return Err(WorkerError::new(format!(
            "Harness worker {name} is not a file: {}",
            path.display()
        )));
    }
    Ok(())
}

fn validate_override(path: &Path, name: &str, expected_version: &str) -> Result<(), WorkerError> {
    validate_regular_worker(path, name)?;
    let output = Command::new(path)
        .arg("--version")
        .output()
        .map_err(|error| {
            WorkerError::new(format!(
                "probe Harness worker {name} at {}: {error}",
                path.display()
            ))
        })?;
    if !output.status.success() {
        return Err(WorkerError::new(format!(
            "Harness worker {name} version probe failed with {}",
            output.status
        )));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let actual_version = stdout.split_whitespace().last().unwrap_or_default();
    if actual_version != expected_version {
        return Err(WorkerError::new(format!(
            "Harness worker {name} version mismatch: expected {expected_version}, got {actual_version}"
        )));
    }
    Ok(())
}

#[cfg(unix)]
fn exec(command: &mut Command, worker: &Path) -> Result<i32, WorkerError> {
    use std::os::unix::process::CommandExt as _;

    let error = command.exec();
    Err(exec_error(worker, &error))
}

#[cfg(not(unix))]
fn exec(command: &mut Command, worker: &Path) -> Result<i32, WorkerError> {
    let status = command
        .status()
        .map_err(|error| exec_error(worker, &error))?;
    Ok(status.code().unwrap_or(1))
}

fn exec_error(worker: &Path, error: &io::Error) -> WorkerError {
    WorkerError::new(format!(
        "execute Harness worker {}: {error}",
        worker.display()
    ))
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    #[cfg(unix)]
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;

    #[cfg(unix)]
    use super::resolve_sibling_worker;
    use super::{resolve_worker, routed_args_from, validate_worker_name};

    fn strings(args: Vec<OsString>) -> Vec<String> {
        args.into_iter()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn worker_names_cannot_escape_the_sibling_directory() {
        for name in ["", ".", "..", "../harness-daemon", "nested/worker"] {
            assert!(validate_worker_name(name).is_err(), "accepted {name:?}");
        }
        assert!(validate_worker_name("harness-daemon").is_ok());
    }

    #[test]
    fn missing_sibling_does_not_fall_back_to_path() {
        let error = resolve_worker(
            "harness-worker-that-does-not-exist",
            env!("CARGO_PKG_VERSION"),
        )
        .expect_err("missing worker");
        assert!(
            error
                .to_string()
                .contains("harness-worker-that-does-not-exist")
        );
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_executable_resolves_worker_beside_canonical_target() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let release_directory = temporary.path().join("release/bin");
        let shadow_directory = temporary.path().join("shadow");
        fs::create_dir_all(&release_directory).expect("create release directory");
        fs::create_dir_all(&shadow_directory).expect("create shadow directory");

        let executable = release_directory.join("harness");
        let worker = release_directory.join("harness-daemon");
        fs::write(&executable, "root").expect("write root executable");
        fs::write(&worker, "worker").expect("write worker executable");
        let shadow_executable = shadow_directory.join("harness");
        symlink(&executable, &shadow_executable).expect("link shadow executable");

        let resolved = resolve_sibling_worker(&shadow_executable, "harness-daemon")
            .expect("resolve canonical sibling");
        let canonical_executable = executable.canonicalize().expect("canonical executable");
        assert_eq!(
            resolved,
            canonical_executable
                .parent()
                .expect("release directory")
                .join("harness-daemon")
        );
    }

    #[cfg(unix)]
    #[test]
    fn broken_executable_symlink_fails_before_shadow_sibling_lookup() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let shadow_directory = temporary.path().join("shadow");
        fs::create_dir_all(&shadow_directory).expect("create shadow directory");

        let shadow_executable = shadow_directory.join("harness");
        symlink(
            temporary.path().join("missing-release/bin/harness"),
            &shadow_executable,
        )
        .expect("link broken shadow executable");
        fs::write(shadow_directory.join("harness-daemon"), "decoy").expect("write shadow decoy");

        let error = resolve_sibling_worker(&shadow_executable, "harness-daemon")
            .expect_err("broken executable link must fail");
        assert!(error.to_string().contains("resolve current executable at"));
        assert!(error.to_string().contains("shadow/harness"));
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_executable_does_not_use_worker_beside_shadow_link() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let release_directory = temporary.path().join("release/bin");
        let shadow_directory = temporary.path().join("shadow");
        fs::create_dir_all(&release_directory).expect("create release directory");
        fs::create_dir_all(&shadow_directory).expect("create shadow directory");

        let executable = release_directory.join("harness");
        fs::write(&executable, "root").expect("write root executable");
        let shadow_executable = shadow_directory.join("harness");
        symlink(&executable, &shadow_executable).expect("link shadow executable");
        fs::write(shadow_directory.join("harness-daemon"), "decoy").expect("write shadow decoy");

        let error = resolve_sibling_worker(&shadow_executable, "harness-daemon")
            .expect_err("canonical sibling is missing");
        assert!(error.to_string().contains("release/bin/harness-daemon"));
        assert!(!error.to_string().contains("shadow/harness-daemon"));
    }

    #[test]
    fn routed_args_remove_delay_already_applied_by_root() {
        for argv in [
            vec!["harness", "daemon", "--delay", "0.25", "status", "--json"],
            vec!["harness", "daemon", "status", "--delay=0.25", "--json"],
        ] {
            let args = routed_args_from(argv, "daemon").expect("daemon route");
            assert_eq!(strings(args), ["status", "--json"]);
        }
    }

    #[test]
    fn routed_args_preserve_worker_values_after_option_terminator() {
        let args = routed_args_from(
            ["harness", "daemon", "status", "--", "--delay", "literal"],
            "daemon",
        )
        .expect("daemon route");
        assert_eq!(strings(args), ["status", "--", "--delay", "literal"]);
    }
}
