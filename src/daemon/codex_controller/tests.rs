use std::sync::{Arc, OnceLock};

use tokio::sync::broadcast;

use super::CodexControllerHandle;
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest};

#[test]
fn start_run_rejects_empty_prompt_before_db_lookup() {
    let (sender, _) = broadcast::channel(8);
    let controller = CodexControllerHandle::new(sender, Arc::new(OnceLock::new()), false);
    let request = CodexRunRequest {
        actor: None,
        prompt: "   ".to_string(),
        mode: CodexRunMode::Report,
        resume_thread_id: None,
        model: None,
    };

    let error = controller
        .start_run("sess-1", &request)
        .expect_err("empty prompt should be rejected");
    assert!(
        error.to_string().contains("codex prompt cannot be empty"),
        "unexpected error: {error}"
    );
}

#[test]
fn start_run_rejects_unknown_model_for_codex() {
    let (sender, _) = broadcast::channel(8);
    let controller = CodexControllerHandle::new(sender, Arc::new(OnceLock::new()), false);
    let request = CodexRunRequest {
        actor: None,
        prompt: "investigate".to_string(),
        mode: CodexRunMode::Report,
        resume_thread_id: None,
        model: Some("not-a-codex-model".to_string()),
    };

    let error = controller
        .start_run("sess-1", &request)
        .expect_err("invalid model should be rejected");
    let message = error.to_string();
    assert!(
        message.contains("not-a-codex-model"),
        "unexpected error: {message}"
    );
    assert!(
        message.contains("gpt-5-codex"),
        "error should list valid codex models: {message}"
    );
}
