use std::cell::Cell;
use std::path::{Path, PathBuf};

use crate::errors::CliError;
use crate::session::service as session_service;
use crate::session::types::SessionRole;

use super::paths::{
    WatchPathTarget, session_id_from_path, session_id_from_path_with, watch_target_from_path,
};
use super::state::RuntimeSessionResolveCache;
use super::test_support::{start_active_session, with_temp_project};

#[test]
fn session_id_from_path_extracts_known_layouts() {
    with_temp_project(|project| {
        let state = start_active_session(
            project,
            "63347873-6ae0-54c7-ac1a-2f69f034825f",
            "watch mapping",
        );
        let joined = temp_env::with_vars(
            [(
                "CODEX_SESSION_ID",
                Some("008d974f-c6a9-53e5-a62e-d331367c449a"),
            )],
            || {
                session_service::join_session(
                    "63347873-6ae0-54c7-ac1a-2f69f034825f",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker")
            },
        );
        let worker = joined
            .agents
            .values()
            .find(|agent| agent.agent_id.starts_with("codex-"))
            .expect("worker");
        let context_root = crate::workspace::project_context_dir(project);

        assert_eq!(
            session_id_from_path(
                &context_root
                    .join("orchestration/sessions/63347873-6ae0-54c7-ac1a-2f69f034825f/state.json")
            )
            .expect("orchestration path"),
            Some("63347873-6ae0-54c7-ac1a-2f69f034825f".to_string())
        );
        assert_eq!(
            session_id_from_path(
                &context_root
                    .join("agents/sessions/codex/008d974f-c6a9-53e5-a62e-d331367c449a/raw.jsonl")
            )
            .expect("runtime transcript path"),
            Some("63347873-6ae0-54c7-ac1a-2f69f034825f".to_string())
        );
        assert_eq!(
            session_id_from_path(&context_root.join(
                "agents/signals/codex/008d974f-c6a9-53e5-a62e-d331367c449a/pending/sig.json"
            ))
            .expect("runtime signal path"),
            Some("63347873-6ae0-54c7-ac1a-2f69f034825f".to_string())
        );
        assert_eq!(
            session_id_from_path(&context_root.join(
                "agents/signals/codex/63347873-6ae0-54c7-ac1a-2f69f034825f/pending/sig.json"
            ))
            .expect("legacy signal path"),
            None
        );
        assert_eq!(
            session_id_from_path(
                &context_root.join(
                    "agents/observe/observe-63347873-6ae0-54c7-ac1a-2f69f034825f/snapshot.json"
                )
            )
            .expect("observe path"),
            Some("63347873-6ae0-54c7-ac1a-2f69f034825f".to_string())
        );
        assert_eq!(
            worker.agent_session_id.as_deref(),
            Some("008d974f-c6a9-53e5-a62e-d331367c449a")
        );
        assert_eq!(state.session_id, "63347873-6ae0-54c7-ac1a-2f69f034825f");
    });
}

#[test]
fn runtime_session_cache_reuses_resolution_until_orchestration_changes() {
    let context_root = PathBuf::from("/tmp/watch-cache/context");
    let transcript_path =
        context_root.join("agents/sessions/codex/008d974f-c6a9-53e5-a62e-d331367c449a/raw.jsonl");
    let orchestration_path =
        context_root.join("orchestration/sessions/63347873-6ae0-54c7-ac1a-2f69f034825f/state.json");
    let mut cache = RuntimeSessionResolveCache::default();
    let resolve_calls = Cell::new(0_usize);
    let mut resolver = |root: &Path,
                        runtime_name: &str,
                        runtime_session_id: &str|
     -> Result<Option<String>, CliError> {
        resolve_calls.set(resolve_calls.get() + 1);
        assert_eq!(root, context_root.as_path());
        assert_eq!(runtime_name, "codex");
        assert_eq!(runtime_session_id, "008d974f-c6a9-53e5-a62e-d331367c449a");
        Ok(Some("63347873-6ae0-54c7-ac1a-2f69f034825f".to_string()))
    };

    assert_eq!(
        session_id_from_path_with(&transcript_path, &mut cache, &mut resolver)
            .expect("first resolution"),
        Some("63347873-6ae0-54c7-ac1a-2f69f034825f".to_string())
    );
    assert_eq!(resolve_calls.get(), 1);

    assert_eq!(
        session_id_from_path_with(&transcript_path, &mut cache, &mut resolver)
            .expect("cached resolution"),
        Some("63347873-6ae0-54c7-ac1a-2f69f034825f".to_string())
    );
    assert_eq!(resolve_calls.get(), 1);

    cache.invalidate_paths(&[orchestration_path]);
    assert_eq!(
        session_id_from_path_with(&transcript_path, &mut cache, &mut resolver)
            .expect("revalidated resolution"),
        Some("63347873-6ae0-54c7-ac1a-2f69f034825f".to_string())
    );
    assert_eq!(resolve_calls.get(), 2);
}

#[test]
fn runtime_session_cache_reuses_negative_resolution_until_orchestration_changes() {
    let context_root = PathBuf::from("/tmp/watch-cache/context");
    let transcript_path =
        context_root.join("agents/sessions/codex/008d974f-c6a9-53e5-a62e-d331367c449a/raw.jsonl");
    let orchestration_path =
        context_root.join("orchestration/sessions/63347873-6ae0-54c7-ac1a-2f69f034825f/state.json");
    let mut cache = RuntimeSessionResolveCache::default();
    let resolve_calls = Cell::new(0_usize);
    let mut resolver = |root: &Path,
                        runtime_name: &str,
                        runtime_session_id: &str|
     -> Result<Option<String>, CliError> {
        resolve_calls.set(resolve_calls.get() + 1);
        assert_eq!(root, context_root.as_path());
        assert_eq!(runtime_name, "codex");
        assert_eq!(runtime_session_id, "008d974f-c6a9-53e5-a62e-d331367c449a");
        Ok(None)
    };

    assert_eq!(
        session_id_from_path_with(&transcript_path, &mut cache, &mut resolver)
            .expect("first negative resolution"),
        None
    );
    assert_eq!(resolve_calls.get(), 1);

    assert_eq!(
        session_id_from_path_with(&transcript_path, &mut cache, &mut resolver)
            .expect("cached negative resolution"),
        None
    );
    assert_eq!(resolve_calls.get(), 1);

    cache.invalidate_paths(&[orchestration_path]);
    assert_eq!(
        session_id_from_path_with(&transcript_path, &mut cache, &mut resolver)
            .expect("revalidated negative resolution"),
        None
    );
    assert_eq!(resolve_calls.get(), 2);
}

#[test]
fn watch_target_from_path_marks_runtime_transcripts_as_targeted_refreshes() {
    with_temp_project(|project| {
        let _state = start_active_session(
            project,
            "63347873-6ae0-54c7-ac1a-2f69f034825f",
            "watch mapping",
        );
        temp_env::with_vars(
            [(
                "CODEX_SESSION_ID",
                Some("008d974f-c6a9-53e5-a62e-d331367c449a"),
            )],
            || {
                session_service::join_session(
                    "63347873-6ae0-54c7-ac1a-2f69f034825f",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("join worker")
            },
        );
        let context_root = crate::workspace::project_context_dir(project);

        assert_eq!(
            watch_target_from_path(
                &context_root
                    .join("orchestration/sessions/63347873-6ae0-54c7-ac1a-2f69f034825f/state.json")
            )
            .expect("orchestration target"),
            Some(WatchPathTarget::Session(
                "63347873-6ae0-54c7-ac1a-2f69f034825f".to_string()
            ))
        );
        assert_eq!(
            watch_target_from_path(
                &context_root
                    .join("agents/sessions/codex/008d974f-c6a9-53e5-a62e-d331367c449a/raw.jsonl")
            )
            .expect("runtime transcript target"),
            Some(WatchPathTarget::Transcript {
                session_id: "63347873-6ae0-54c7-ac1a-2f69f034825f".to_string(),
                runtime_name: "codex".to_string(),
                runtime_session_id: "008d974f-c6a9-53e5-a62e-d331367c449a".to_string(),
            })
        );
        assert_eq!(
            watch_target_from_path(
                &context_root.join(
                    "agents/observe/observe-63347873-6ae0-54c7-ac1a-2f69f034825f/snapshot.json"
                )
            )
            .expect("observe target"),
            Some(WatchPathTarget::Session(
                "63347873-6ae0-54c7-ac1a-2f69f034825f".to_string()
            ))
        );
        assert_eq!(
            watch_target_from_path(&context_root.join(
                "agents/signals/codex/008d974f-c6a9-53e5-a62e-d331367c449a/pending/sig.json"
            ))
            .expect("runtime signal target"),
            Some(WatchPathTarget::Session(
                "63347873-6ae0-54c7-ac1a-2f69f034825f".to_string()
            ))
        );
    });
}
