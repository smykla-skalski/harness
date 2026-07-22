use std::io::{self, Read, Write as _};
use std::process::{Child, ChildStderr, ChildStdin, ChildStdout, ExitStatus};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, ScopedJoinHandle};
use std::time::{Duration, Instant};

use super::GitProcessLimits;

#[derive(Debug)]
pub(super) struct CollectedGitOutput {
    pub(super) status: ExitStatus,
    pub(super) stdout: Vec<u8>,
    pub(super) stderr: Vec<u8>,
    pub(super) timed_out: bool,
}

struct ClassifiedChildOutcome {
    result: io::Result<(ExitStatus, bool)>,
}

pub(super) struct WriterFailure {
    pub(super) error: io::Error,
}

pub(super) fn collect_child_output(
    child: &mut Child,
    stdin: Option<ChildStdin>,
    stdout: ChildStdout,
    stderr: ChildStderr,
    input: Option<&[u8]>,
    max_bytes: u64,
    limits: Option<GitProcessLimits>,
) -> io::Result<CollectedGitOutput> {
    thread::scope(|scope| {
        let input_failed = Arc::new(AtomicBool::new(false));
        let writer_failure = Arc::clone(&input_failed);
        let writer = scope.spawn(move || write_stdin(stdin, input, &writer_failure));
        let overflow = Arc::new(AtomicBool::new(false));
        let stdout_overflow = Arc::clone(&overflow);
        let stderr_overflow = Arc::clone(&overflow);
        let stdout_reader =
            scope.spawn(move || read_and_flag_overflow(stdout, max_bytes, &stdout_overflow));
        let stderr_reader =
            scope.spawn(move || read_and_flag_overflow(stderr, 1024 * 1024, &stderr_overflow));
        let deadline = limits.map(|limits| Instant::now() + limits.wall_time);
        let outcome = wait_for_child(child, &input_failed, &overflow, deadline);
        let stdout = join_io(stdout_reader, "git stdout reader panicked");
        let stderr = join_io(stderr_reader, "git stderr reader panicked");
        let writer = join_writer(writer);

        let writer = writer?;
        if let Some(failure) = writer
            && writer_failure_is_primary(&failure, outcome.result.is_ok())
        {
            return Err(failure.error);
        }
        let (status, timed_out) = outcome.result?;
        Ok(CollectedGitOutput {
            status,
            stdout: stdout?,
            stderr: stderr?,
            timed_out,
        })
    })
}

fn write_stdin(
    mut stdin: Option<ChildStdin>,
    input: Option<&[u8]>,
    input_failed: &AtomicBool,
) -> Option<WriterFailure> {
    if let (Some(stdin), Some(input)) = (&mut stdin, input)
        && let Err(error) = stdin.write_all(input)
    {
        let failure = WriterFailure { error };
        input_failed.store(true, Ordering::Release);
        return Some(failure);
    }
    None
}

fn read_and_flag_overflow(
    reader: impl Read,
    max_bytes: u64,
    overflow: &AtomicBool,
) -> io::Result<Vec<u8>> {
    let bytes = read_capped(reader, max_bytes);
    if bytes.is_err() || bytes.as_ref().is_ok_and(|bytes| exceeds(bytes, max_bytes)) {
        overflow.store(true, Ordering::Release);
    }
    bytes
}

fn wait_for_child(
    child: &mut Child,
    input_failed: &AtomicBool,
    overflow: &AtomicBool,
    deadline: Option<Instant>,
) -> ClassifiedChildOutcome {
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                return classified(Ok((status, false)));
            }
            Ok(None) if input_failed.load(Ordering::Acquire) => {
                let _ = child.kill();
                return ClassifiedChildOutcome {
                    result: child.wait().map(|status| (status, false)),
                };
            }
            Ok(None) if overflow.load(Ordering::Acquire) => {
                let _ = child.kill();
                return ClassifiedChildOutcome {
                    result: child.wait().map(|status| (status, false)),
                };
            }
            Ok(None) if deadline.is_some_and(|deadline| Instant::now() >= deadline) => {
                let _ = child.kill();
                return ClassifiedChildOutcome {
                    result: child.wait().map(|status| (status, true)),
                };
            }
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(error) => {
                let outcome = classified(Err(error));
                let _ = child.kill();
                let _ = child.wait();
                return outcome;
            }
        }
    }
}

fn classified(result: io::Result<(ExitStatus, bool)>) -> ClassifiedChildOutcome {
    ClassifiedChildOutcome { result }
}

pub(super) fn writer_failure_is_primary(
    failure: &WriterFailure,
    child_status_obtained: bool,
) -> bool {
    failure.error.kind() != io::ErrorKind::BrokenPipe || !child_status_obtained
}

fn join_writer(
    handle: ScopedJoinHandle<'_, Option<WriterFailure>>,
) -> io::Result<Option<WriterFailure>> {
    handle
        .join()
        .map_err(|_| io::Error::other("git stdin writer panicked"))
}

fn join_io<T>(
    handle: ScopedJoinHandle<'_, io::Result<T>>,
    panic_message: &'static str,
) -> io::Result<T> {
    handle.join().map_err(|_| io::Error::other(panic_message))?
}

pub(super) fn read_capped(reader: impl Read, max_bytes: u64) -> io::Result<Vec<u8>> {
    let capacity = usize::try_from(max_bytes.min(1024 * 1024)).unwrap_or(1024 * 1024);
    let mut bytes = Vec::with_capacity(capacity);
    reader
        .take(max_bytes.saturating_add(1))
        .read_to_end(&mut bytes)?;
    Ok(bytes)
}

pub(super) fn exceeds(bytes: &[u8], max_bytes: u64) -> bool {
    u64::try_from(bytes.len())
        .ok()
        .is_none_or(|size| size > max_bytes)
}
