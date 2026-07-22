use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::Duration;

use crate::git::{GitError, GitResult};

#[path = "command/bounded.rs"]
mod bounded;
#[cfg(test)]
use bounded::{WriterFailure, read_capped, writer_failure_is_primary};
use bounded::{collect_child_output, exceeds};

const GIT_ROUTING_ENVIRONMENT: [&str; 17] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_QUARANTINE_PATH",
    "GIT_NAMESPACE",
    "GIT_PREFIX",
    "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_PARAMETERS",
    "GIT_EXEC_PATH",
    "GIT_SHALLOW_FILE",
    "GIT_REPLACE_REF_BASE",
    "GIT_NO_REPLACE_OBJECTS",
];

pub(super) struct GitCommandRunner<'a> {
    worktree: &'a Path,
    route: Option<GitRepositoryRoute>,
    object_store: Option<GitObjectStore>,
}

struct GitRepositoryRoute {
    git_dir: PathBuf,
    common_dir: PathBuf,
}

struct GitObjectStore {
    object_directory: PathBuf,
    alternate_object_directories: OsString,
}

#[derive(Debug, Clone, Copy)]
pub(super) struct GitProcessLimits {
    pub(super) wall_time: Duration,
    pub(super) cpu_seconds: u64,
    pub(super) address_space_bytes: u64,
    pub(super) alloc_limit_bytes: u64,
    pub(super) file_bytes: u64,
}

impl<'a> GitCommandRunner<'a> {
    pub(super) const fn new(worktree: &'a Path) -> Self {
        Self {
            worktree,
            route: None,
            object_store: None,
        }
    }

    pub(super) fn routed(worktree: &'a Path, git_dir: &Path, common_dir: &Path) -> Self {
        Self {
            worktree,
            route: Some(GitRepositoryRoute {
                git_dir: git_dir.to_path_buf(),
                common_dir: common_dir.to_path_buf(),
            }),
            object_store: None,
        }
    }

    pub(super) fn with_object_store(
        mut self,
        object_directory: &Path,
        alternate_object_directory: &Path,
    ) -> GitResult<Self> {
        let alternate_object_directories = std::env::join_paths([alternate_object_directory])
            .map_err(|error| {
                GitError::unsafe_state(
                    self.worktree,
                    format!("Git alternate object path is not representable: {error}"),
                )
            })?;
        self.object_store = Some(GitObjectStore {
            object_directory: object_directory.to_path_buf(),
            alternate_object_directories,
        });
        Ok(self)
    }

    pub(super) fn read<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.output(args, false, &[0])
    }

    pub(super) fn contract<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        let output = self.output(args, false, &[0, 1, 128])?;
        if output.status.success() {
            Ok(output)
        } else {
            Err(GitError::unsafe_state(self.worktree, stderr(&output)))
        }
    }

    pub(super) fn probe<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.output(args, false, &[0, 1])
    }

    pub(super) fn mutation<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.output(args, true, &[0])
    }

    pub(super) fn mutation_bounded_stdout<const N: usize>(
        &self,
        args: [&str; N],
        max_bytes: u64,
    ) -> GitResult<Output> {
        self.bounded_stdout(args, None, max_bytes, true, &[0], None)
    }

    pub(super) fn read_bounded_stdout<const N: usize>(
        &self,
        args: [&str; N],
        max_bytes: u64,
    ) -> GitResult<Output> {
        self.bounded_stdout(args, None, max_bytes, false, &[0], None)
    }

    pub(super) fn mutation_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &[u8],
    ) -> GitResult<Output> {
        self.bounded_stdout(args, Some(input), 64 * 1024, true, &[0], None)
    }

    pub(super) fn read_bounded_stdout_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &[u8],
        max_bytes: u64,
    ) -> GitResult<Output> {
        self.bounded_stdout(args, Some(input), max_bytes, false, &[0], None)
    }

    pub(super) fn contract_bounded_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &[u8],
        max_bytes: u64,
    ) -> GitResult<Output> {
        let output =
            self.bounded_stdout(args, Some(input), max_bytes, false, &[0, 1, 128], None)?;
        if output.status.success() {
            Ok(output)
        } else {
            Err(GitError::unsafe_state(self.worktree, stderr(&output)))
        }
    }

    pub(super) fn mutation_bounded_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &[u8],
        max_bytes: u64,
    ) -> GitResult<Output> {
        self.bounded_stdout(args, Some(input), max_bytes, true, &[0], None)
    }

    pub(super) fn contract_resource_limited_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &[u8],
        max_bytes: u64,
        limits: GitProcessLimits,
    ) -> GitResult<Output> {
        let output = self.bounded_stdout(
            args,
            Some(input),
            max_bytes,
            false,
            &[0, 1, 128],
            Some(limits),
        )?;
        if output.status.success() {
            Ok(output)
        } else {
            Err(GitError::unsafe_state(self.worktree, stderr(&output)))
        }
    }

    pub(super) fn read_resource_limited_stdout<const N: usize>(
        &self,
        args: [&str; N],
        max_bytes: u64,
        limits: GitProcessLimits,
    ) -> GitResult<Output> {
        self.bounded_stdout(args, None, max_bytes, false, &[0], Some(limits))
    }

    pub(super) fn mutation_resource_limited_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &[u8],
        max_bytes: u64,
        limits: GitProcessLimits,
    ) -> GitResult<Output> {
        self.bounded_stdout(args, Some(input), max_bytes, true, &[0], Some(limits))
    }

    fn bounded_stdout<const N: usize>(
        &self,
        args: [&str; N],
        input: Option<&[u8]>,
        max_bytes: u64,
        mutation: bool,
        ok_codes: &[i32],
        limits: Option<GitProcessLimits>,
    ) -> GitResult<Output> {
        let mut command = self.command(args);
        if let Some(limits) = limits {
            apply_process_limits(&mut command, limits);
        }
        let mut child = command
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .spawn()
            .map_err(|error| operation_error(self.worktree, mutation, error))?;
        let stdin = input
            .map(|_| {
                child.stdin.take().ok_or_else(|| {
                    operation_error(self.worktree, mutation, "git stdin is unavailable")
                })
            })
            .transpose()?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| operation_error(self.worktree, mutation, "git stdout is unavailable"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| operation_error(self.worktree, mutation, "git stderr is unavailable"))?;
        let collected =
            collect_child_output(&mut child, stdin, stdout, stderr, input, max_bytes, limits)
                .map_err(|error| operation_error(self.worktree, mutation, error))?;
        if collected.timed_out {
            let detail = "git operation exceeded its wall-clock contract";
            return if mutation {
                Err(GitError::mutation(self.worktree, detail))
            } else {
                Err(GitError::unsafe_state(self.worktree, detail))
            };
        }
        if exceeds(&collected.stdout, max_bytes) || exceeds(&collected.stderr, 1024 * 1024) {
            return Err(GitError::unsafe_state(
                self.worktree,
                "git output exceeds its byte contract",
            ));
        }
        if limits.is_some() && !mutation && !collected.status.success() {
            let detail = String::from_utf8_lossy(&collected.stderr).trim().to_owned();
            return Err(GitError::unsafe_state(
                self.worktree,
                if detail.is_empty() {
                    "git operation exceeded its resource contract".to_owned()
                } else {
                    detail
                },
            ));
        }
        require_status(
            self.worktree,
            Output {
                status: collected.status,
                stdout: collected.stdout,
                stderr: collected.stderr,
            },
            mutation,
            ok_codes,
        )
    }

    fn output<const N: usize>(
        &self,
        args: [&str; N],
        mutation: bool,
        ok_codes: &[i32],
    ) -> GitResult<Output> {
        let output = self
            .command(args)
            .stdin(Stdio::null())
            .output()
            .map_err(|error| {
                if mutation {
                    GitError::mutation(self.worktree, error)
                } else {
                    GitError::read(self.worktree, error)
                }
            })?;
        require_status(self.worktree, output, mutation, ok_codes)
    }

    fn command<const N: usize>(&self, args: [&str; N]) -> Command {
        let mut command = Command::new("git");
        command
            .arg("-C")
            .arg(self.worktree)
            .args([
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "submodule.recurse=false",
            ])
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for variable in GIT_ROUTING_ENVIRONMENT {
            command.env_remove(variable);
        }
        if let Some(route) = &self.route {
            command
                .env("GIT_DIR", &route.git_dir)
                .env("GIT_COMMON_DIR", &route.common_dir)
                .env("GIT_WORK_TREE", self.worktree);
        }
        if let Some(store) = &self.object_store {
            command
                .env("GIT_OBJECT_DIRECTORY", &store.object_directory)
                .env("GIT_QUARANTINE_PATH", &store.object_directory)
                .env(
                    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                    &store.alternate_object_directories,
                );
        }
        command.env("GIT_NO_REPLACE_OBJECTS", "1");
        command
    }
}

#[allow(unsafe_code)]
fn apply_process_limits(command: &mut Command, limits: GitProcessLimits) {
    use std::os::unix::process::CommandExt as _;

    // GIT_ALLOC_LIMIT caps any single Git allocation and is honored on every platform, so
    // it bounds transient index-pack memory where the Linux-only RLIMIT_AS cannot (macOS).
    // Git sizes an object's buffer from its header before inflating, so an oversized delta
    // result is rejected before it is decompressed.
    command.env("GIT_ALLOC_LIMIT", limits.alloc_limit_bytes.to_string());
    // SAFETY: the closure performs only async-signal-safe setrlimit calls before exec.
    unsafe {
        command.pre_exec(move || {
            set_resource_limit(libc::RLIMIT_CPU, limits.cpu_seconds)?;
            set_address_space_limit(limits.address_space_bytes)?;
            set_resource_limit(libc::RLIMIT_FSIZE, limits.file_bytes)
        });
    }
}

// macOS rejects setrlimit(RLIMIT_AS) with EINVAL (it won't lower the cap below the
// pre-exec child's current usage); Linux permits it, so this cap is Linux-only. Off Linux
// GIT_ALLOC_LIMIT (set in apply_process_limits) is the transient-memory guard: it rejects
// an oversized single allocation before inflation, while the post-hoc verify-pack sizes and
// the CPU/wall-clock budget remain the backstops.
#[cfg(target_os = "linux")]
fn set_address_space_limit(bytes: u64) -> std::io::Result<()> {
    set_resource_limit(libc::RLIMIT_AS, bytes)
}

#[cfg(not(target_os = "linux"))]
fn set_address_space_limit(_bytes: u64) -> std::io::Result<()> {
    Ok(())
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code)]
fn set_resource_limit(resource: libc::__rlimit_resource_t, value: u64) -> std::io::Result<()> {
    let limit = resource_limit(value)?;
    // SAFETY: limit points to a fully initialized rlimit for this child process.
    if unsafe { libc::setrlimit(resource, &limit) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "linux"))]
#[allow(unsafe_code)]
fn set_resource_limit(resource: libc::c_int, value: u64) -> std::io::Result<()> {
    let limit = resource_limit(value)?;
    // SAFETY: limit points to a fully initialized rlimit for this child process.
    if unsafe { libc::setrlimit(resource, &limit) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn resource_limit(value: u64) -> std::io::Result<libc::rlimit> {
    let value = libc::rlim_t::try_from(value)
        .map_err(|_| std::io::Error::other("Git resource limit overflowed"))?;
    Ok(libc::rlimit {
        rlim_cur: value,
        rlim_max: value,
    })
}

fn require_status(
    worktree: &Path,
    output: Output,
    mutation: bool,
    ok_codes: &[i32],
) -> GitResult<Output> {
    if output
        .status
        .code()
        .is_some_and(|code| ok_codes.contains(&code))
    {
        return Ok(output);
    }
    let detail = stderr(&output);
    if mutation {
        Err(GitError::mutation(worktree, detail))
    } else {
        Err(GitError::read(worktree, detail))
    }
}

fn operation_error(path: &Path, mutation: bool, error: impl std::fmt::Display) -> GitError {
    if mutation {
        GitError::mutation(path, error)
    } else {
        GitError::read(path, error)
    }
}

pub(super) fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).trim().to_string()
}

#[cfg(test)]
#[path = "command/tests.rs"]
mod tests;
