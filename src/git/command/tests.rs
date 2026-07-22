use std::ffi::OsStr;
use std::io::{Cursor, Read as _};

use super::*;

#[test]
fn every_git_command_scrubs_repository_routing_environment() {
    let command = GitCommandRunner::new(Path::new("/tmp/frozen-worktree")).command(["status"]);
    let args = command
        .get_args()
        .map(|arg| arg.to_string_lossy())
        .collect::<Vec<_>>();
    assert!(
        args.windows(2)
            .any(|pair| { pair[0] == "-c" && pair[1] == "core.hooksPath=/dev/null" })
    );
    assert!(
        args.windows(2)
            .any(|pair| { pair[0] == "-c" && pair[1] == "submodule.recurse=false" })
    );
    for variable in GIT_ROUTING_ENVIRONMENT {
        if variable == "GIT_NO_REPLACE_OBJECTS" {
            continue;
        }
        assert_eq!(
            command
                .get_envs()
                .find(|(name, _)| *name == OsStr::new(variable))
                .map(|(_, value)| value),
            Some(None),
            "{variable} was inherited by an exact-worktree Git command"
        );
    }
    assert_eq!(
        command
            .get_envs()
            .find(|(name, _)| *name == OsStr::new("GIT_NO_REPLACE_OBJECTS")),
        Some((OsStr::new("GIT_NO_REPLACE_OBJECTS"), Some(OsStr::new("1"))))
    );
}

#[test]
fn capped_reader_accepts_exact_limit_and_exposes_one_extra_byte() {
    let exact = read_capped(Cursor::new(vec![b'x'; 8]), 8).expect("read exact bytes");
    assert_eq!(exact.len(), 8);
    assert!(!exceeds(&exact, 8));

    let extra = read_capped(Cursor::new(vec![b'x'; 9]), 8).expect("read max plus one");
    assert_eq!(extra.len(), 9);
    assert!(exceeds(&extra, 8));
}

#[test]
fn resource_timeout_is_not_masked_by_a_closed_stdin_pipe() {
    let temp = tempfile::tempdir().expect("git command fixture");
    let input = vec![b'x'; 1024 * 1024];
    let error = GitCommandRunner::new(temp.path())
        .contract_resource_limited_with_input(
            ["hash-object", "--stdin"],
            &input,
            128,
            GitProcessLimits {
                wall_time: std::time::Duration::ZERO,
                cpu_seconds: 1,
                address_space_bytes: 512 * 1024 * 1024,
                alloc_limit_bytes: 512 * 1024 * 1024,
                file_bytes: 1024 * 1024,
            },
        )
        .expect_err("resource timeout must fail closed");

    let GitError::Unsafe { message, .. } = error else {
        panic!("closed stdin masked the primary resource timeout")
    };
    assert_eq!(message, "git operation exceeded its wall-clock contract");
}

#[cfg(unix)]
#[test]
fn early_child_stdin_close_is_subordinate_to_the_child_status() {
    let mut child = Command::new("sh")
        .args(["-c", "exec 0<&-; printf x; exit 17"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn closed-input child");
    let stdin = child.stdin.take().expect("child stdin");
    let mut stdout = child.stdout.take().expect("child stdout");
    let stderr = child.stderr.take().expect("child stderr");
    let mut ready = [0_u8; 1];
    stdout
        .read_exact(&mut ready)
        .expect("child closed stdin before collection");
    assert_eq!(ready, [b'x']);
    let input = vec![b'x'; 1024 * 1024];

    let output = collect_child_output(
        &mut child,
        Some(stdin),
        stdout,
        stderr,
        Some(&input),
        128,
        Some(GitProcessLimits {
            wall_time: std::time::Duration::from_secs(1),
            cpu_seconds: 1,
            address_space_bytes: 512 * 1024 * 1024,
            alloc_limit_bytes: 512 * 1024 * 1024,
            file_bytes: 1024 * 1024,
        }),
    )
    .expect("child status must win over its closed stdin pipe");

    assert!(!output.status.success());
    assert!(!output.timed_out);
}

#[test]
fn deterministic_index_pack_rejection_is_unsafe() {
    let temp = tempfile::tempdir().expect("git command fixture");
    Command::new("git")
        .args(["init", "--quiet"])
        .arg(temp.path())
        .status()
        .expect("initialize Git fixture");
    let mut input = b"NOT_A_PACK".to_vec();
    input.resize(1024 * 1024, b'x');
    let error = GitCommandRunner::new(temp.path())
        .contract_resource_limited_with_input(
            ["index-pack", "--stdin", "--fix-thin"],
            &input,
            128,
            GitProcessLimits {
                wall_time: std::time::Duration::from_secs(1),
                cpu_seconds: 1,
                address_space_bytes: 512 * 1024 * 1024,
                alloc_limit_bytes: 512 * 1024 * 1024,
                file_bytes: 2 * 1024 * 1024,
            },
        )
        .expect_err("deterministic invalid pack must fail closed");

    assert!(matches!(error, GitError::Unsafe { .. }));
}

#[test]
fn bounded_input_accepts_a_successful_git_command() {
    let temp = tempfile::tempdir().expect("git command fixture");
    let output = GitCommandRunner::new(temp.path())
        .contract_resource_limited_with_input(
            ["hash-object", "--stdin"],
            b"bounded input",
            128,
            GitProcessLimits {
                wall_time: std::time::Duration::from_secs(1),
                cpu_seconds: 1,
                address_space_bytes: 512 * 1024 * 1024,
                alloc_limit_bytes: 512 * 1024 * 1024,
                file_bytes: 1024 * 1024,
            },
        )
        .expect("bounded Git input succeeds");

    assert!(!output.stdout.is_empty());
}

#[test]
fn git_alloc_limit_fails_closed_on_an_oversized_allocation() {
    let temp = tempfile::tempdir().expect("git command fixture");
    // Git must grow a 1 MiB stdin buffer, far above the 256 KiB single-allocation ceiling,
    // so GIT_ALLOC_LIMIT aborts the child before the allocation completes. This is the
    // cross-platform transient-memory guard that also holds where RLIMIT_AS is a no-op.
    let input = vec![b'x'; 1024 * 1024];
    let error = GitCommandRunner::new(temp.path())
        .contract_resource_limited_with_input(
            ["hash-object", "--stdin"],
            &input,
            128,
            GitProcessLimits {
                wall_time: std::time::Duration::from_secs(5),
                cpu_seconds: 5,
                address_space_bytes: 512 * 1024 * 1024,
                alloc_limit_bytes: 256 * 1024,
                file_bytes: 2 * 1024 * 1024,
            },
        )
        .expect_err("oversized allocation must fail closed under GIT_ALLOC_LIMIT");

    assert!(matches!(error, GitError::Unsafe { .. }));
}

#[test]
fn non_broken_pipe_writer_failure_remains_primary() {
    let failure = WriterFailure {
        error: std::io::Error::new(std::io::ErrorKind::InvalidInput, "input failed"),
    };
    assert!(writer_failure_is_primary(&failure, true));
    let closed = WriterFailure {
        error: std::io::Error::new(std::io::ErrorKind::BrokenPipe, "child closed stdin"),
    };
    assert!(!writer_failure_is_primary(&closed, true));
}
