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
    };

    let error = controller
        .start_run("sess-1", &request)
        .expect_err("empty prompt should be rejected");
    assert!(
        error.to_string().contains("codex prompt cannot be empty"),
        "unexpected error: {error}"
    );
}
