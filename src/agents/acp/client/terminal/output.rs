use std::io::{ErrorKind, Read as StdRead};
use std::sync::{Arc, Mutex};
use std::thread;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::TerminalOutputState;

pub(super) fn spawn_output_reader(
    mut reader: Box<dyn StdRead + Send>,
    output: Arc<Mutex<TerminalOutputState>>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => append_with_limit(&output, &buf[..n]),
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
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

pub(super) fn wait_for_output_drain(output: &Mutex<TerminalOutputState>, timeout: Duration) {
    let start = Instant::now();
    let mut previous_len = output.lock().unwrap().output.len();
    while start.elapsed() < timeout {
        thread::sleep(Duration::from_millis(5));
        let len = output.lock().unwrap().output.len();
        if len > 0 && len == previous_len {
            return;
        }
        previous_len = len;
    }
}
