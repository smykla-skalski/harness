use std::io::{ErrorKind, Read};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};

use tokio::sync::broadcast;

use super::screen::TerminalScreenParser;
use super::support::Shared;

pub(crate) struct ReadinessState {
    pub(crate) ready: bool,
    pub(crate) closed: bool,
}

pub(crate) type ReadinessSignal = Arc<(Mutex<ReadinessState>, Condvar)>;

pub(crate) fn new_readiness_signal() -> ReadinessSignal {
    Arc::new((
        Mutex::new(ReadinessState {
            ready: false,
            closed: false,
        }),
        Condvar::new(),
    ))
}

fn check_readiness_pattern(
    transcript: &[u8],
    chunk_len: usize,
    pattern: &[u8],
    readiness: &ReadinessSignal,
) -> bool {
    let search_start = transcript
        .len()
        .saturating_sub(chunk_len + pattern.len() - 1);
    let tail = &transcript[search_start..];
    if tail.windows(pattern.len()).any(|window| window == pattern) {
        signal_readiness_ready(readiness);
        return true;
    }
    false
}

pub(crate) fn signal_readiness_ready(readiness: &ReadinessSignal) {
    if let Ok(mut state) = readiness.0.lock() {
        state.ready = true;
    }
    readiness.1.notify_all();
}

pub(crate) fn signal_readiness_closed(readiness: &ReadinessSignal) {
    if let Ok(mut state) = readiness.0.lock() {
        state.closed = true;
    }
    readiness.1.notify_all();
}

pub(crate) fn spawn_reader_thread(
    mut reader: Box<dyn Read + Send>,
    transcript: Shared<Vec<u8>>,
    screen: Shared<TerminalScreenParser>,
    readiness_pattern: Option<&'static str>,
    screen_text_fallback: bool,
    readiness: ReadinessSignal,
    broadcast_tx: broadcast::Sender<Vec<u8>>,
) -> JoinHandle<()> {
    let pattern_bytes = readiness_pattern.map(|pattern| pattern.as_bytes().to_vec());

    thread::spawn(move || {
        let mut signaled = false;
        let mut buffer = [0_u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => {
                    let bytes = &buffer[..read];
                    let data = bytes.to_vec();
                    let _ = broadcast_tx.send(data);

                    if let Ok(mut transcript) = transcript.lock() {
                        transcript.extend_from_slice(bytes);
                        if !signaled && let Some(pattern) = &pattern_bytes {
                            signaled =
                                check_readiness_pattern(&transcript, read, pattern, &readiness);
                        }
                    }
                    if let Ok(mut screen) = screen.lock() {
                        screen.process(bytes);
                        if !signaled && screen_text_fallback && !screen.snapshot().text.is_empty() {
                            signal_readiness_ready(&readiness);
                            signaled = true;
                        }
                    }
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
        signal_readiness_closed(&readiness);
    })
}
