use super::*;

#[test]
fn disconnect_reason_maps_initialize_deadline() {
    let error = deadline_error("session/initialize", Duration::from_millis(25));

    assert_eq!(
        disconnect_reason_from_error(&error),
        DisconnectReason::InitializeTimeout
    );
}

#[test]
fn disconnect_reason_maps_prompt_deadline() {
    let error = deadline_error("session/prompt", Duration::from_millis(25));

    assert_eq!(
        disconnect_reason_from_error(&error),
        DisconnectReason::PromptTimeout
    );
}

#[test]
fn disconnect_reason_keeps_non_deadline_errors_as_stdio_closed() {
    let error = AcpError::new(-32603, "session/prompt internal failure");

    assert_eq!(
        disconnect_reason_from_error(&error),
        DisconnectReason::StdioClosed
    );
}
