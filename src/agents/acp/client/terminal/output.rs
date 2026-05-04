use std::io::{ErrorKind, Read as StdRead};
use std::sync::{Arc, Mutex};
use std::thread;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::{TerminalOutputState, TerminalWaitSignal};

pub(super) fn spawn_output_reader(
    mut reader: Box<dyn StdRead + Send>,
    output: Arc<Mutex<TerminalOutputState>>,
    signal: Arc<TerminalWaitSignal>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    append_with_limit(&output, &buf[..n]);
                    signal.note_output_updated();
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
        signal.note_reader_closed();
    })
}

/// Append bytes to a buffer with a limit, truncating from the front if needed.
pub(super) fn append_with_limit(output: &Mutex<TerminalOutputState>, data: &[u8]) {
    let mut output = output.lock().unwrap();
    output.output.extend_from_slice(data);
    let limit = usize::try_from(output.output_limit).unwrap_or(usize::MAX);
    if limit == 0 {
        output.output.clear();
        output.truncated = true;
        return;
    }
    if output.output.len() > limit {
        let start = output.output.len() - limit;
        output.output.drain(..start);
        output.truncated = true;
    }
}

pub(super) fn wait_for_output_drain(signal: &TerminalWaitSignal, timeout: Duration) {
    let start = Instant::now();
    let mut snapshot = signal.snapshot();
    while start.elapsed() < timeout {
        if snapshot.reader_closed {
            return;
        }
        let remaining = timeout.saturating_sub(start.elapsed());
        let next = signal.wait_for_change(snapshot, remaining);
        if next.generation == snapshot.generation && next.reader_closed == snapshot.reader_closed {
            return;
        }
        snapshot = next;
    }
}
