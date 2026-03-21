use std::io;

use super::*;

#[test]
fn block_error_new_preserves_fields() {
    let error = BlockError::new("process", "run echo hello", io::Error::other("boom"));
    assert_eq!(error.block, "process");
    assert_eq!(error.operation, "run echo hello");
    assert_eq!(error.cause.to_string(), "boom");
}

#[test]
fn block_error_display_format() {
    let error = BlockError::message("http", "request", "timeout");
    assert_eq!(error.to_string(), "[http] request: timeout");
}

#[test]
fn block_error_source_is_cause() {
    let error = BlockError::message("docker", "inspect", "not found");
    let source = error.source().expect("expected source");
    assert_eq!(source.to_string(), "not found");
}

#[test]
fn block_error_into_cli_error_code_and_message() {
    let error = BlockError::message("process", "run", "failed");
    let cli: CliError = error.into();
    assert_eq!(cli.code(), "KSRCLI004");
    assert_eq!(cli.message(), "command failed: [process] run");
    assert_eq!(cli.details(), Some("failed"));
}

#[test]
fn block_error_message_without_typed_cause() {
    let error = BlockError::message("kubernetes", "apply", "bad manifest");
    assert_eq!(error.cause.to_string(), "bad manifest");
}

#[test]
fn block_error_is_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<BlockError>();
}
