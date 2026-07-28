//! Daemon-routing coverage for `session_commands.rs`'s `SessionAdoptArgs`.
//! Lives alongside the managed-agent groups because it shares the same
//! `session::transport::support::daemon_client()` back-edge fix and fake-daemon
//! fixtures, even though the command itself is a sibling of `managed_agents`.

use harness_workspace::command_context::{AppContext, Execute};

use harness::session::service;
use harness::session::transport::SessionAdoptArgs;
use harness::session::wire::SessionMutationResponse;

use super::support::run_against_fake_daemon;

#[test]
fn session_adopt_routes_through_leaf_client() {
    let session_id = "00000000-0000-4000-8000-00000000b010";
    let state = service::build_new_session_with_policy(
        "daemon routing ctx",
        "daemon routing",
        session_id,
        "leaderless",
        None,
        "2026-04-24T00:00:00Z",
        None,
    );
    let response =
        serde_json::to_string(&SessionMutationResponse { state }).expect("serialize state");
    let captured = run_against_fake_daemon(response, || {
        let args = SessionAdoptArgs {
            path: "/tmp/example-session".into(),
            bookmark_id: Some("bookmark-1".into()),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/sessions/adopt");
    assert!(captured.body.contains("\"bookmark_id\":\"bookmark-1\""));
    assert!(
        captured
            .body
            .contains("\"session_root\":\"/tmp/example-session\"")
    );
}
