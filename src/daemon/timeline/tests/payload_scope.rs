use temp_env::with_vars;
use tempfile::tempdir;

use super::super::{TimelinePayloadScope, session_timeline, session_timeline_with_scope};
use super::support::{context_root, write_standard_timeline_fixture};

#[test]
fn session_timeline_summary_scope_keeps_entries_but_omits_payloads() {
    let tmp = tempdir().expect("tempdir");
    with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = context_root(tmp.path());
            let session_id = "sess-summary";
            write_standard_timeline_fixture(&context_root, session_id);

            let full_entries = session_timeline(session_id).expect("full timeline");
            let summary_entries =
                session_timeline_with_scope(session_id, TimelinePayloadScope::Summary)
                    .expect("summary timeline");

            assert_eq!(summary_entries.len(), full_entries.len());
            assert!(
                summary_entries
                    .iter()
                    .all(|entry| entry.payload == serde_json::json!({}))
            );
            assert_eq!(
                summary_entries
                    .iter()
                    .map(|entry| (&entry.entry_id, &entry.kind, &entry.summary))
                    .collect::<Vec<_>>(),
                full_entries
                    .iter()
                    .map(|entry| (&entry.entry_id, &entry.kind, &entry.summary))
                    .collect::<Vec<_>>()
            );
        },
    );
}
