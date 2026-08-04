//! Bounded capture for Codex app-server failure diagnostics.

use std::collections::VecDeque;
use std::io::{self, Read, Write as _};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

use nix::fcntl::{FcntlArg, OFlag, fcntl};
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};

const CODEX_STDERR_TAIL_BYTES: usize = 16 * 1024;
const CODEX_STDERR_DRAIN_BATCH_BYTES: usize = 1024 * 1024;

pub(super) struct CodexStderrCapture {
    tail: Arc<Mutex<BoundedTail>>,
    reader: Option<JoinHandle<()>>,
    finish_signal: UnixStream,
}

impl CodexStderrCapture {
    pub(super) fn start<R>(mut source: R) -> io::Result<Self>
    where
        R: AsFd + Read + Send + 'static,
    {
        make_nonblocking(&source)?;
        let (finish_reader, finish_signal) = UnixStream::pair()?;
        let tail = Arc::new(Mutex::new(BoundedTail::new(CODEX_STDERR_TAIL_BYTES)));
        let reader_tail = Arc::clone(&tail);
        let reader = thread::Builder::new()
            .name("codex-stderr-capture".to_owned())
            .spawn(move || capture_stderr(&mut source, &finish_reader, &reader_tail))?;
        Ok(Self {
            tail,
            reader: Some(reader),
            finish_signal,
        })
    }

    pub(super) fn snapshot(&self) -> String {
        snapshot(&self.tail)
    }

    pub(super) fn finish(&mut self) -> String {
        self.stop_reader();
        self.snapshot()
    }

    fn stop_reader(&mut self) {
        let Some(reader) = self.reader.take() else {
            return;
        };
        let _ = self.finish_signal.write_all(&[1]);
        let _ = reader.join();
    }
}

impl Drop for CodexStderrCapture {
    fn drop(&mut self) {
        self.stop_reader();
    }
}

fn capture_stderr<R>(source: &mut R, finish_reader: &UnixStream, tail: &Mutex<BoundedTail>)
where
    R: AsFd + Read,
{
    loop {
        let Ok((source_ready, finish_requested)) = wait_for_input(source, finish_reader) else {
            append(tail, b"stderr capture poll failed");
            return;
        };
        if finish_requested {
            let _ = drain_available(source, tail, CODEX_STDERR_DRAIN_BATCH_BYTES);
            return;
        }
        if source_ready
            && drain_available(source, tail, CODEX_STDERR_DRAIN_BATCH_BYTES) == DrainResult::Closed
        {
            return;
        }
    }
}

fn wait_for_input(source: &impl AsFd, finish_reader: &UnixStream) -> io::Result<(bool, bool)> {
    loop {
        let mut descriptors = [
            PollFd::new(source.as_fd(), PollFlags::POLLIN),
            PollFd::new(finish_reader.as_fd(), PollFlags::POLLIN),
        ];
        match poll(&mut descriptors, PollTimeout::NONE) {
            Ok(_) => {
                return Ok((
                    descriptors[0].any().unwrap_or_default(),
                    descriptors[1].any().unwrap_or_default(),
                ));
            }
            Err(nix::errno::Errno::EINTR) => {}
            Err(error) => return Err(io::Error::from(error)),
        }
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum DrainResult {
    Drained,
    Closed,
}

fn drain_available<R>(source: &mut R, tail: &Mutex<BoundedTail>, byte_limit: usize) -> DrainResult
where
    R: Read,
{
    let mut buffer = [0_u8; 4096];
    let mut drained = 0;
    while drained < byte_limit {
        let remaining = byte_limit.saturating_sub(drained);
        let read_len = buffer.len().min(remaining);
        match source.read(&mut buffer[..read_len]) {
            Ok(0) => return DrainResult::Closed,
            Ok(read) => {
                append(tail, &buffer[..read]);
                drained += read;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                return DrainResult::Drained;
            }
            Err(error) => {
                append(tail, format!("stderr capture failed: {error}").as_bytes());
                return DrainResult::Closed;
            }
        }
    }
    DrainResult::Drained
}

fn make_nonblocking(source: &impl AsFd) -> io::Result<()> {
    let flags = fcntl(source, FcntlArg::F_GETFL).map_err(io::Error::from)?;
    let flags = OFlag::from_bits_truncate(flags) | OFlag::O_NONBLOCK;
    fcntl(source, FcntlArg::F_SETFL(flags)).map_err(io::Error::from)?;
    Ok(())
}

fn append(tail: &Mutex<BoundedTail>, bytes: &[u8]) {
    if let Ok(mut tail) = tail.lock() {
        tail.append(bytes);
    }
}

fn snapshot(tail: &Mutex<BoundedTail>) -> String {
    tail.lock().map_or_else(
        |_| "stderr capture unavailable".to_owned(),
        |tail| tail.snapshot(),
    )
}

struct BoundedTail {
    bytes: VecDeque<u8>,
    capacity: usize,
}

impl BoundedTail {
    fn new(capacity: usize) -> Self {
        Self {
            bytes: VecDeque::with_capacity(capacity),
            capacity,
        }
    }

    fn append(&mut self, bytes: &[u8]) {
        self.bytes.extend(bytes);
        let overflow = self.bytes.len().saturating_sub(self.capacity);
        self.bytes.drain(..overflow);
    }

    fn snapshot(&self) -> String {
        let bytes = self.bytes.iter().copied().collect::<Vec<_>>();
        String::from_utf8_lossy(&bytes).trim().to_owned()
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write as _;
    use std::os::unix::net::UnixStream;
    use std::sync::mpsc;

    use super::*;

    #[test]
    fn capture_retains_only_the_bounded_tail() {
        let mut output = vec![b'x'; CODEX_STDERR_TAIL_BYTES + 128];
        output.extend_from_slice(b"diagnostic-end");
        let (source, mut writer) = UnixStream::pair().expect("stderr pipe");
        let mut capture = CodexStderrCapture::start(source).expect("start capture");
        writer.write_all(&output).expect("write diagnostics");

        let tail = capture.finish();

        assert!(tail.len() <= CODEX_STDERR_TAIL_BYTES);
        assert!(tail.ends_with("diagnostic-end"));
    }

    #[test]
    fn finish_stops_while_writer_is_continuously_readable() {
        let (source, mut writer) = UnixStream::pair().expect("stderr pipe");
        let mut capture = CodexStderrCapture::start(source).expect("start capture");
        let (started_tx, started_rx) = mpsc::channel();
        let writer = thread::spawn(move || {
            let output = [b'x'; 4096];
            writer.write_all(&output).expect("initial diagnostics");
            started_tx.send(()).expect("signal initial diagnostics");
            while writer.write_all(&output).is_ok() {}
        });
        started_rx.recv().expect("wait for initial diagnostics");

        let tail = capture.finish();
        writer.join().expect("join diagnostic writer");

        assert!(!tail.is_empty());
        assert!(tail.len() <= CODEX_STDERR_TAIL_BYTES);
    }
}
