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
        let state = start_active_session(project, "watch-map", "watch mapping");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
            session_service::join_session(
                "watch-map",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker")
        });
        let worker = joined
            .agents
            .values()
            .find(|agent| agent.agent_id.starts_with("codex-"))
            .expect("worker");
        let context_root = crate::workspace::project_context_dir(project);

        assert_eq!(
            session_id_from_path(&context_root.join("orchestration/sessions/watch-map/state.json"))
                .expect("orchestration path"),
            Some("watch-map".to_string())
        );
        assert_eq!(
            session_id_from_path(
                &context_root.join("agents/sessions/codex/worker-session/raw.jsonl")
            )
            .expect("runtime transcript path"),
            Some("watch-map".to_string())
        );
        assert_eq!(
            session_id_from_path(
                &context_root.join("agents/signals/codex/worker-session/pending/sig.json")
            )
            .expect("runtime signal path"),
            Some("watch-map".to_string())
        );
        assert_eq!(
            session_id_from_path(
                &context_root.join("agents/signals/codex/watch-map/pending/sig.json")
            )
            .expect("legacy signal path"),
            Some("watch-map".to_string())
        );
        assert_eq!(
            session_id_from_path(
                &context_root.join("agents/observe/observe-watch-map/snapshot.json")
            )
            .expect("observe path"),
            Some("watch-map".to_string())
        );
        assert_eq!(worker.agent_session_id.as_deref(), Some("worker-session"));
        assert_eq!(state.session_id, "watch-map");
    });
}

#[test]
fn runtime_session_cache_reuses_resolution_until_orchestration_changes() {
    let context_root = PathBuf::from("/tmp/watch-cache/context");
    let transcript_path = context_root.join("agents/sessions/codex/worker-session/raw.jsonl");
    let orchestration_path = context_root.join("orchestration/sessions/watch-map/state.json");
    let mut cache = RuntimeSessionResolveCache::default();
    let resolve_calls = Cell::new(0_usize);
    let mut resolver = |root: &Path,
                        runtime_name: &str,
                        runtime_session_id: &str|
     -> Result<Option<String>, CliError> {
        resolve_calls.set(resolve_calls.get() + 1);
        assert_eq!(root, context_root.as_path());
        assert_eq!(runtime_name, "codex");
        assert_eq!(runtime_session_id, "worker-session");
        Ok(Some("watch-map".to_string()))
    };

    assert_eq!(
        session_id_from_path_with(&transcript_path, &mut cache, &mut resolver)
            .expect("first resolution"),
        Some("watch-map".to_string())
    );
    assert_eq!(resolve_calls.get(), 1);

    assert_eq!(
        session_id_from_path_with(&transcript_path, &mut cache, &mut resolver)
            .expect("cached resolution"),
        Some("watch-map".to_string())
    );
    assert_eq!(resolve_calls.get(), 1);

    cache.invalidate_paths(&[orchestration_path]);
    assert_eq!(
        session_id_from_path_with(&transcript_path, &mut cache, &mut resolver)
            .expect("revalidated resolution"),
        Some("watch-map".to_string())
    );
    assert_eq!(resolve_calls.get(), 2);
}

#[test]
fn runtime_session_cache_reuses_negative_resolution_until_orchestration_changes() {
    let context_root = PathBuf::from("/tmp/watch-cache/context");
    let transcript_path = context_root.join("agents/sessions/codex/worker-session/raw.jsonl");
    let orchestration_path = context_root.join("orchestration/sessions/watch-map/state.json");
    let mut cache = RuntimeSessionResolveCache::default();
    let resolve_calls = Cell::new(0_usize);
    let mut resolver = |root: &Path,
                        runtime_name: &str,
                        runtime_session_id: &str|
     -> Result<Option<String>, CliError> {
        resolve_calls.set(resolve_calls.get() + 1);
        assert_eq!(root, context_root.as_path());
        assert_eq!(runtime_name, "codex");
        assert_eq!(runtime_session_id, "worker-session");
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
        let _state = start_active_session(project, "watch-map", "watch mapping");
        temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
            session_service::join_session(
                "watch-map",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker")
        });
        let context_root = crate::workspace::project_context_dir(project);

        assert_eq!(
            watch_target_from_path(
                &context_root.join("orchestration/sessions/watch-map/state.json")
            )
            .expect("orchestration target"),
            Some(WatchPathTarget::Session("watch-map".to_string()))
        );
        assert_eq!(
            watch_target_from_path(
                &context_root.join("agents/sessions/codex/worker-session/raw.jsonl")
            )
            .expect("runtime transcript target"),
            Some(WatchPathTarget::Transcript {
                session_id: "watch-map".to_string(),
                runtime_name: "codex".to_string(),
                runtime_session_id: "worker-session".to_string(),
            })
        );
        assert_eq!(
            watch_target_from_path(
                &context_root.join("agents/observe/observe-watch-map/snapshot.json")
            )
            .expect("observe target"),
            Some(WatchPathTarget::Session("watch-map".to_string()))
        );
        assert_eq!(
            watch_target_from_path(
                &context_root.join("agents/signals/codex/worker-session/pending/sig.json")
            )
            .expect("runtime signal target"),
            Some(WatchPathTarget::Session("watch-map".to_string()))
        );
    });
}
