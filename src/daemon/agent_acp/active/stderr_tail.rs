use std::io::Read;
use std::process::ChildStderr;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

use super::{STDERR_READER_JOIN_GRACE, STDERR_READER_JOIN_POLL, STDERR_TAIL_LIMIT, recover_lock};

#[derive(Clone, Default)]
pub(in crate::daemon::agent_acp) struct SharedStderrTail {
    bytes: Arc<Mutex<Vec<u8>>>,
    reader: Arc<Mutex<Option<thread::JoinHandle<()>>>>,
}

impl SharedStderrTail {
    pub(in crate::daemon::agent_acp) fn spawn(stderr: Option<ChildStderr>) -> Self {
        let tail = Self::default();
        if let Some(mut stderr) = stderr {
            let writer = tail.clone();
            let reader = thread::spawn(move || {
                let mut buffer = [0_u8; 4096];
                while let Ok(n) = stderr.read(&mut buffer) {
                    if n == 0 {
                        break;
                    }
                    writer.append(&buffer[..n]);
                }
            });
            *recover_lock(&tail.reader, "stderr tail reader lock") = Some(reader);
        }
        tail
    }

    pub(in crate::daemon::agent_acp) fn shutdown(&self) {
        if let Some(reader) = take_reader(self) {
            shutdown_reader(reader);
        }
    }

    fn append(&self, bytes: &[u8]) {
        let mut tail = recover_lock(&self.bytes, "stderr tail lock");
        tail.extend_from_slice(bytes);
        if tail.len() > STDERR_TAIL_LIMIT {
            let excess = tail.len() - STDERR_TAIL_LIMIT;
            tail.drain(..excess);
        }
    }

    pub(in crate::daemon::agent_acp) fn as_string(&self) -> Option<String> {
        let tail = recover_lock(&self.bytes, "stderr tail lock");
        if tail.is_empty() {
            None
        } else {
            Some(String::from_utf8_lossy(&tail).into_owned())
        }
    }
}

fn reader_finished_before_deadline(reader: &thread::JoinHandle<()>) -> bool {
    let deadline = Instant::now() + STDERR_READER_JOIN_GRACE;
    while !reader.is_finished() {
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(STDERR_READER_JOIN_POLL);
    }
    true
}

fn take_reader(tail: &SharedStderrTail) -> Option<thread::JoinHandle<()>> {
    recover_lock(&tail.reader, "stderr tail reader lock").take()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn shutdown_reader(reader: thread::JoinHandle<()>) {
    if reader_finished_before_deadline(&reader) {
        let _ = reader.join();
    } else {
        tracing::warn!("ACP stderr reader still running after shutdown grace; detaching");
    }
}
