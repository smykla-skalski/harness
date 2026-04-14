use temp_env::with_vars;
use tempfile::tempdir;

use super::super::session_timeline;
use super::support::{context_root, write_copilot_ledger_fixture};

#[test]
fn session_timeline_uses_ledger_fallback_for_copilot_tool_events() {
    let tmp = tempdir().expect("tempdir");
    with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = context_root(tmp.path());
            let session_id = "sess-copilot";
            write_copilot_ledger_fixture(&context_root, session_id);

            let entries = session_timeline(session_id).expect("timeline");
            assert_eq!(entries.len(), 2);
            assert_eq!(entries[0].kind, "tool_result");
            assert_eq!(
                entries[0].summary,
                "copilot-worker received a result from Read"
            );
            assert_eq!(entries[1].kind, "tool_invocation");
            assert_eq!(entries[1].summary, "copilot-worker invoked Read");
        },
    );
}
