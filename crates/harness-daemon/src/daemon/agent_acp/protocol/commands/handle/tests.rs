use super::*;

/// The loop bounds every request it makes, so a missing reply means the loop
/// itself stopped running. The caller is a blocked thread, and on the teardown
/// path it holds the process-lifecycle lock, so it has to come back either way.
#[test]
fn close_session_gives_up_when_the_loop_never_answers() {
    let (cancel_tx, _cancel_rx) = tokio_mpsc::unbounded_channel();
    // Held, not dropped: the send has to succeed so this exercises the silent
    // loop rather than the closed-channel path below.
    let (command_tx, _command_rx) = tokio_mpsc::unbounded_channel();
    let handle = AcpProtocolHandle::new(cancel_tx, command_tx, Duration::from_millis(150));

    let started = std::time::Instant::now();
    let result = handle.close_session("acp-session-1");

    let Err(message) = result else {
        unreachable!("close must not succeed with no loop to answer it");
    };
    assert!(
        message.contains("did not answer"),
        "error should name the unanswered command; got {message}"
    );
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "caller waited {:?}, which is past its own bound",
        started.elapsed()
    );
}

#[test]
fn close_session_reports_a_closed_channel_separately_from_a_silent_loop() {
    let (cancel_tx, _cancel_rx) = tokio_mpsc::unbounded_channel();
    let (command_tx, command_rx) = tokio_mpsc::unbounded_channel();
    drop(command_rx);
    let handle = AcpProtocolHandle::new(cancel_tx, command_tx, Duration::from_secs(30));

    let result = handle.close_session("acp-session-1");

    let Err(message) = result else {
        unreachable!("close must not succeed on a closed channel");
    };
    assert!(
        message.contains("closed"),
        "error should name the closed channel; got {message}"
    );
}
