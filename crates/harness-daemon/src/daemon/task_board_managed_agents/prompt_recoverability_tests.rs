//! The prompt an agent ran with stays readable next to what it produced.
//!
//! A Codex-backed agent carries its prompt on the run row, so for each render
//! site this saves the run the way the controller saves it and reads the row
//! back, asserting the exact rendered bytes come back alongside the run's
//! final message. The controller's own tests cover the other half of the
//! chain, that a request's prompt is what lands on the snapshot it persists.
//! The terminal transport has no such column and is covered by
//! `agent_tui::tests::started_prompt`.

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::AgentMode;
use crate::task_board::render_triage_escalation_prompt;

use super::super::test_support::{applied_task, codex_snapshot, seed_session, test_http_state};
use super::super::{codex_worker_request, managed_worker_id};
use super::{review_launch, write_launch};

/// Persist a run the way the controller does -- prompt carried from the
/// request, result carried in the final message -- and read it back.
async fn round_trip(db: &AsyncDaemonDb, run_id: &str, session_id: &str, prompt: &str) -> String {
    let mut snapshot = codex_snapshot(CodexRunStatus::Completed, session_id);
    snapshot.run_id = run_id.to_string();
    snapshot.prompt = prompt.to_string();
    snapshot.final_message = Some("{\"verdict\":\"pass\"}".into());
    db.save_codex_run(&snapshot).await.expect("save codex run");
    let reloaded = db
        .codex_run(run_id)
        .await
        .expect("reload codex run")
        .expect("run row exists");
    assert_eq!(
        reloaded.final_message.as_deref(),
        Some("{\"verdict\":\"pass\"}"),
        "the prompt must be recoverable alongside the result, not instead of it"
    );
    reloaded.prompt
}

#[tokio::test]
async fn a_worker_run_keeps_the_prompt_it_started_with() {
    let state = test_http_state();
    let db = state.async_db.get().cloned().expect("test async db");
    let applied = applied_task(AgentMode::Headless);
    seed_session(&db, &applied.session_id).await;
    let run_id = managed_worker_id(&applied, "dispatch-intent-1");
    let request = codex_worker_request(&applied, &run_id).expect("render worker request");

    let recovered = round_trip(&db, &run_id, &applied.session_id, &request.prompt).await;

    assert_eq!(recovered, request.prompt);
}

#[tokio::test]
async fn an_implementation_run_keeps_the_prompt_it_started_with() {
    let state = test_http_state();
    let db = state.async_db.get().cloned().expect("test async db");
    let mut applied = applied_task(AgentMode::Headless);
    applied.write_workflow = Some(Box::new(write_launch()));
    seed_session(&db, &applied.session_id).await;
    let run_id = "codex-implementation-attempt";
    let request = codex_worker_request(&applied, run_id).expect("render write request");

    let recovered = round_trip(&db, run_id, &applied.session_id, &request.prompt).await;

    assert_eq!(recovered, request.prompt);
}

#[tokio::test]
async fn a_review_run_keeps_the_prompt_it_started_with() {
    let state = test_http_state();
    let db = state.async_db.get().cloned().expect("test async db");
    let mut applied = applied_task(AgentMode::Evaluate);
    applied.read_only_workflow = Some(review_launch());
    seed_session(&db, &applied.session_id).await;
    let run_id = "codex-review-attempt";
    let request = codex_worker_request(&applied, run_id).expect("render review request");

    let recovered = round_trip(&db, run_id, &applied.session_id, &request.prompt).await;

    assert_eq!(recovered, request.prompt);
}

#[tokio::test]
async fn an_escalation_run_keeps_the_prompt_it_started_with() {
    let state = test_http_state();
    let db = state.async_db.get().cloned().expect("test async db");
    let applied = applied_task(AgentMode::Headless);
    seed_session(&db, &applied.session_id).await;
    let prompt = render_triage_escalation_prompt(
        &applied.item,
        "escalation-1",
        "token-1",
        "sha256:fingerprint-1",
    )
    .expect("render escalation prompt");

    let recovered = round_trip(&db, "codex-escalation-1", &applied.session_id, &prompt).await;

    assert_eq!(recovered, prompt);
}
