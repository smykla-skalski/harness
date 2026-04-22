use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::daemon::agent_tui::{
    AgentTuiInput, AgentTuiInputSequence, AgentTuiInputSequenceStep, AgentTuiInputWorker,
};

use super::support::{WAIT_TIMEOUT, spawn_shell, wait_until};

#[test]
fn input_worker_replays_timed_sequences_in_order() {
    let process = Arc::new(spawn_shell("cat"));
    let stop_flag = Arc::new(AtomicBool::new(false));
    let worker = AgentTuiInputWorker::spawn(Arc::clone(&process), Arc::clone(&stop_flag));
    let sequence = AgentTuiInputSequence {
        steps: vec![
            AgentTuiInputSequenceStep {
                delay_before_ms: 0,
                input: AgentTuiInput::Text {
                    text: "first\n".into(),
                },
            },
            AgentTuiInputSequenceStep {
                delay_before_ms: 120,
                input: AgentTuiInput::Text {
                    text: "second\n".into(),
                },
            },
        ],
    };

    let started = Instant::now();
    worker.enqueue_sequence(&sequence).expect("queue sequence");

    wait_until(WAIT_TIMEOUT, || transcript_text(&process).contains("first"));
    assert!(
        !transcript_text(&process).contains("second"),
        "delayed step should not replay immediately"
    );

    std::thread::sleep(Duration::from_millis(60));
    assert!(
        !transcript_text(&process).contains("second"),
        "delayed step should still be pending midway through the idle window"
    );

    wait_until(WAIT_TIMEOUT, || transcript_text(&process).contains("second"));
    assert!(
        started.elapsed() >= Duration::from_millis(120),
        "second step should not replay before its configured delay"
    );

    process.kill().expect("kill cat");
}

#[test]
fn input_worker_keeps_immediate_input_ordered_after_in_flight_sequence() {
    let process = Arc::new(spawn_shell("cat"));
    let stop_flag = Arc::new(AtomicBool::new(false));
    let worker = AgentTuiInputWorker::spawn(Arc::clone(&process), Arc::clone(&stop_flag));
    let sequence = AgentTuiInputSequence {
        steps: vec![
            AgentTuiInputSequenceStep {
                delay_before_ms: 0,
                input: AgentTuiInput::Text {
                    text: "first\n".into(),
                },
            },
            AgentTuiInputSequenceStep {
                delay_before_ms: 120,
                input: AgentTuiInput::Text {
                    text: "second\n".into(),
                },
            },
        ],
    };

    worker.enqueue_sequence(&sequence).expect("queue sequence");
    let queued_worker = worker.clone();
    let sender = std::thread::spawn(move || {
        queued_worker.send_input(&AgentTuiInput::Text {
            text: "third\n".into(),
        })
    });

    wait_until(WAIT_TIMEOUT, || transcript_text(&process).contains("third"));
    sender
        .join()
        .expect("join queued immediate input")
        .expect("send third");

    let transcript = transcript_text(&process);
    let first = transcript.find("first").expect("first in transcript");
    let second = transcript.find("second").expect("second in transcript");
    let third = transcript.find("third").expect("third in transcript");
    assert!(first < second && second < third, "{transcript}");

    process.kill().expect("kill cat");
}

#[test]
fn input_worker_aborts_pending_replay_after_stop_or_exit() {
    let process = Arc::new(spawn_shell("cat"));
    let stop_flag = Arc::new(AtomicBool::new(false));
    let worker = AgentTuiInputWorker::spawn(Arc::clone(&process), Arc::clone(&stop_flag));
    let sequence = AgentTuiInputSequence {
        steps: vec![
            AgentTuiInputSequenceStep {
                delay_before_ms: 0,
                input: AgentTuiInput::Text {
                    text: "first\n".into(),
                },
            },
            AgentTuiInputSequenceStep {
                delay_before_ms: 250,
                input: AgentTuiInput::Text {
                    text: "blocked\n".into(),
                },
            },
        ],
    };

    worker.enqueue_sequence(&sequence).expect("queue sequence");
    wait_until(WAIT_TIMEOUT, || transcript_text(&process).contains("first"));

    stop_flag.store(true, Ordering::Relaxed);
    process.kill().expect("kill cat");
    std::thread::sleep(Duration::from_millis(300));

    let transcript = transcript_text(&process);
    assert!(!transcript.contains("blocked"), "{transcript}");
    let error = worker
        .send_input(&AgentTuiInput::Text {
            text: "later\n".into(),
        })
        .expect_err("stopped worker should reject new input");
    assert!(error.to_string().contains("no longer active"));
}

fn transcript_text(process: &Arc<crate::daemon::agent_tui::AgentTuiProcess>) -> String {
    String::from_utf8_lossy(&process.transcript().expect("transcript")).into_owned()
}
