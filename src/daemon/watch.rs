use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use tokio::spawn;
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;
use tokio::time::interval as tokio_interval;
use tracing::warn;

use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::index;
use super::protocol::{SessionSummary, StreamEvent};
use super::{snapshot, timeline};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct SessionDigest {
    detail_json: String,
    timeline_json: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct WatchSnapshot {
    sessions_json: String,
    digests: BTreeMap<String, SessionDigest>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct WatchChanges {
    sessions_updated: bool,
    session_ids: BTreeSet<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RefreshScope {
    SessionScoped,
    Full,
}

/// Spawn the daemon's file-driven refresh loop for SSE subscribers.
#[must_use]
pub fn spawn_watch_loop(
    sender: broadcast::Sender<StreamEvent>,
    interval: Duration,
) -> JoinHandle<()> {
    spawn(async move {
        let root = index::projects_root();
        if let Err(error) = fs_err::create_dir_all(&root) {
            warn!(%error, path = %root.display(), "failed to create daemon watch root");
        }

        let (event_tx, mut event_rx) = mpsc::channel::<notify::Result<notify::Event>>(128);
        let mut watcher = create_watcher(event_tx);
        if watcher.is_none() {
            warn!("failed to create daemon watcher");
        }
        if let Some(watcher_ref) = watcher.as_mut()
            && let Err(error) = watcher_ref.watch(&root, RecursiveMode::Recursive)
        {
            warn!(%error, path = %root.display(), "failed to watch daemon project root");
            watcher = None;
        }

        let mut ticker = tokio_interval(interval);
        let mut snapshot = WatchSnapshot::default();
        let _ = refresh_watch_snapshot(&mut snapshot, &BTreeSet::new(), RefreshScope::Full);

        loop {
            let mut targeted_session_ids = BTreeSet::new();
            let mut scope = if watcher.is_some() {
                RefreshScope::SessionScoped
            } else {
                RefreshScope::Full
            };

            tokio::select! {
                Some(result) = event_rx.recv() => {
                    merge_watch_event(result, &mut targeted_session_ids, &mut scope);
                }
                _ = ticker.tick() => {
                    scope = RefreshScope::Full;
                }
            }

            while let Ok(result) = event_rx.try_recv() {
                merge_watch_event(result, &mut targeted_session_ids, &mut scope);
            }

            let Ok(changes) = refresh_watch_snapshot(&mut snapshot, &targeted_session_ids, scope)
            else {
                continue;
            };
            emit_watch_changes(&sender, changes);
        }
    })
}

fn create_watcher(
    event_tx: mpsc::Sender<notify::Result<notify::Event>>,
) -> Option<RecommendedWatcher> {
    build_watcher(event_tx).ok()
}

fn build_watcher(
    event_tx: mpsc::Sender<notify::Result<notify::Event>>,
) -> notify::Result<RecommendedWatcher> {
    RecommendedWatcher::new(watcher_callback(event_tx), notify::Config::default())
}

fn watcher_callback(
    event_tx: mpsc::Sender<notify::Result<notify::Event>>,
) -> impl FnMut(notify::Result<notify::Event>) + Send + 'static {
    move |result| {
        let _ = event_tx.blocking_send(result);
    }
}

fn merge_watch_event(
    result: notify::Result<notify::Event>,
    targeted_session_ids: &mut BTreeSet<String>,
    scope: &mut RefreshScope,
) {
    let Ok(event) = result else {
        *scope = RefreshScope::Full;
        return;
    };

    let extracted = extract_session_ids(&event.paths);
    if extracted.is_empty() {
        *scope = RefreshScope::Full;
        return;
    }

    targeted_session_ids.extend(extracted);
}

fn extract_session_ids(paths: &[PathBuf]) -> BTreeSet<String> {
    paths
        .iter()
        .filter_map(|path| session_id_from_path(path).ok().flatten())
        .collect()
}

fn session_id_from_path(path: &Path) -> Result<Option<String>, CliError> {
    if let Some(session_id) = orchestration_session_id_from_path(path) {
        return Ok(Some(session_id));
    }
    if let Some((context_root, runtime_name, runtime_session_id)) = runtime_session_target_from_path(path)
    {
        return index::resolve_session_id_for_runtime_session(
            &context_root,
            &runtime_name,
            &runtime_session_id,
        );
    }
    Ok(None)
}

fn orchestration_session_id_from_path(path: &Path) -> Option<String> {
    let components: Vec<_> = path
        .components()
        .filter_map(|component| match component {
            Component::Normal(part) => Some(part.to_string_lossy().to_string()),
            _ => None,
        })
        .collect();
    components.windows(3).find_map(|window| match window {
        [first, second, session_id] if first == "orchestration" && second == "sessions" => {
            Some(session_id.clone())
        }
        _ => None,
    })
}

fn runtime_session_target_from_path(path: &Path) -> Option<(PathBuf, String, String)> {
    runtime_session_target_from_transcript(path).or_else(|| runtime_session_target_from_signal(path))
}

fn runtime_session_target_from_transcript(path: &Path) -> Option<(PathBuf, String, String)> {
    if path.file_name().and_then(|name| name.to_str()) != Some("raw.jsonl") {
        return None;
    }
    let runtime_session_id = path.parent()?.file_name()?.to_string_lossy().to_string();
    let runtime_name = path
        .parent()?
        .parent()?
        .file_name()?
        .to_string_lossy()
        .to_string();
    if path.parent()?.parent()?.parent()?.file_name()?.to_str() != Some("sessions")
        || path.parent()?.parent()?.parent()?.parent()?.file_name()?.to_str() != Some("agents")
    {
        return None;
    }
    Some((path.ancestors().nth(5)?.to_path_buf(), runtime_name, runtime_session_id))
}

fn runtime_session_target_from_signal(path: &Path) -> Option<(PathBuf, String, String)> {
    let signal_bucket = path.parent()?.file_name()?.to_str()?;
    if !matches!(signal_bucket, "pending" | "acknowledged") {
        return None;
    }
    let runtime_session_id = path.parent()?.parent()?.file_name()?.to_string_lossy().to_string();
    let runtime_name = path
        .parent()?
        .parent()?
        .parent()?
        .file_name()?
        .to_string_lossy()
        .to_string();
    if path.parent()?.parent()?.parent()?.parent()?.file_name()?.to_str() != Some("signals")
        || path.parent()?.parent()?.parent()?.parent()?.parent()?.file_name()?.to_str()
            != Some("agents")
    {
        return None;
    }
    Some((path.ancestors().nth(6)?.to_path_buf(), runtime_name, runtime_session_id))
}

fn refresh_watch_snapshot(
    snapshot: &mut WatchSnapshot,
    targeted_session_ids: &BTreeSet<String>,
    scope: RefreshScope,
) -> Result<WatchChanges, CliError> {
    let summaries = snapshot::session_summaries(true)?;
    let sessions_json = encode_payload(&summaries, "daemon session summaries")?;
    let current_session_ids: BTreeSet<_> = summaries
        .iter()
        .map(|summary| summary.session_id.clone())
        .collect();

    let mut changes = WatchChanges {
        sessions_updated: sessions_json != snapshot.sessions_json,
        session_ids: BTreeSet::new(),
    };
    snapshot.sessions_json = sessions_json;

    let digests_to_refresh =
        session_ids_to_refresh(snapshot, &summaries, targeted_session_ids, scope);
    for session_id in &digests_to_refresh {
        if !current_session_ids.contains(session_id) {
            if snapshot.digests.remove(session_id).is_some() {
                changes.sessions_updated = true;
                changes.session_ids.insert(session_id.clone());
            }
            continue;
        }

        let digest = load_session_digest(session_id)?;
        let previous = snapshot.digests.insert(session_id.clone(), digest.clone());
        if previous.as_ref() != Some(&digest) {
            changes.session_ids.insert(session_id.clone());
        }
    }

    prune_removed_sessions(snapshot, &current_session_ids, &mut changes);
    Ok(changes)
}

fn session_ids_to_refresh(
    snapshot: &WatchSnapshot,
    summaries: &[SessionSummary],
    targeted_session_ids: &BTreeSet<String>,
    scope: RefreshScope,
) -> BTreeSet<String> {
    if matches!(scope, RefreshScope::Full) || targeted_session_ids.is_empty() {
        return summaries
            .iter()
            .map(|summary| summary.session_id.clone())
            .chain(snapshot.digests.keys().cloned())
            .collect();
    }

    targeted_session_ids
        .iter()
        .cloned()
        .chain(
            snapshot
                .digests
                .keys()
                .filter(|session_id| targeted_session_ids.contains(*session_id))
                .cloned(),
        )
        .collect()
}

fn load_session_digest(session_id: &str) -> Result<SessionDigest, CliError> {
    let detail = snapshot::session_detail(session_id)?;
    let timeline = timeline::session_timeline(session_id)?;
    Ok(SessionDigest {
        detail_json: encode_payload(&detail, &format!("daemon session detail '{session_id}'"))?,
        timeline_json: encode_payload(&timeline, &format!("daemon timeline '{session_id}'"))?,
    })
}

fn encode_payload<T: serde::Serialize>(value: &T, label: &str) -> Result<String, CliError> {
    serde_json::to_string(value)
        .map_err(|error| CliErrorKind::workflow_io(format!("encode {label}: {error}")).into())
}

fn prune_removed_sessions(
    snapshot: &mut WatchSnapshot,
    current_session_ids: &BTreeSet<String>,
    changes: &mut WatchChanges,
) {
    let removed: Vec<_> = snapshot
        .digests
        .keys()
        .filter(|session_id| !current_session_ids.contains(*session_id))
        .cloned()
        .collect();
    for session_id in removed {
        snapshot.digests.remove(&session_id);
        changes.sessions_updated = true;
        changes.session_ids.insert(session_id);
    }
}

fn emit_watch_changes(sender: &broadcast::Sender<StreamEvent>, changes: WatchChanges) {
    if changes.sessions_updated {
        let _ = sender.send(StreamEvent {
            event: "sessions_updated".into(),
            recorded_at: utc_now(),
            session_id: None,
            payload: serde_json::json!([]),
        });
    }

    for session_id in changes.session_ids {
        let _ = sender.send(StreamEvent {
            event: "session_updated".into(),
            recorded_at: utc_now(),
            session_id: Some(session_id),
            payload: serde_json::json!({}),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::path::Path;

    use fs_err as fs;
    use tempfile::tempdir;

    use crate::agents::runtime;
    use crate::agents::runtime::signal::{AckResult, SignalAck, acknowledge_signal};
    use crate::session::service as session_service;
    use crate::session::types::{SessionRole, TaskSeverity};

    fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("xdg path")),
                ),
                ("CLAUDE_SESSION_ID", Some("leader-session")),
            ],
            || {
                let project = tmp.path().join("project");
                fs::create_dir_all(&project).expect("create project dir");
                test_fn(&project);
            },
        );
    }

    fn append_project_ledger_entry(project_dir: &Path) {
        let ledger_path = crate::workspace::project_context_dir(project_dir)
            .join("agents")
            .join("ledger")
            .join("events.jsonl");
        fs::create_dir_all(ledger_path.parent().expect("ledger dir")).expect("create ledger dir");
        fs::write(
            &ledger_path,
            format!(
                "{{\"sequence\":1,\"recorded_at\":\"2026-03-28T12:00:00Z\",\"cwd\":\"{}\"}}\n",
                project_dir.display()
            ),
        )
        .expect("write ledger");
    }

    #[test]
    fn session_id_from_path_extracts_known_layouts() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "watch mapping",
                project,
                Some("claude"),
                Some("watch-map"),
            )
            .expect("start session");
            let joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
                    session_service::join_session(
                        "watch-map",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
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
                session_id_from_path(
                    &context_root.join("orchestration/sessions/watch-map/state.json")
                )
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
                None
            );
            assert_eq!(worker.agent_session_id.as_deref(), Some("worker-session"));
            assert_eq!(state.session_id, "watch-map");
        });
    }

    #[test]
    fn refresh_watch_snapshot_detects_timeline_only_changes() {
        with_temp_project(|project| {
            let state = session_service::start_session(
                "watch test",
                project,
                Some("claude"),
                Some("watch-sess"),
            )
            .expect("start session");
            let leader_id = state.leader_id.expect("leader id");

            let joined =
                temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
                    session_service::join_session(
                        "watch-sess",
                        SessionRole::Worker,
                        "codex",
                        &[],
                        None,
                        project,
                    )
                    .expect("join worker")
                });
            let worker_id = joined
                .agents
                .keys()
                .find(|agent_id| agent_id.starts_with("codex-"))
                .expect("worker id")
                .clone();
            let worker_session_id = joined
                .agents
                .get(&worker_id)
                .and_then(|agent| agent.agent_session_id.clone())
                .expect("worker session id");
            session_service::create_task(
                "watch-sess",
                "watch timeline",
                None,
                TaskSeverity::Medium,
                &leader_id,
                project,
            )
            .expect("create task");
            append_project_ledger_entry(project);
            let signal = session_service::send_signal(
                "watch-sess",
                &worker_id,
                "inject_context",
                "watch the ack path",
                Some("timeline"),
                &leader_id,
                project,
            )
            .expect("send signal");

            let mut snapshot = WatchSnapshot::default();
            let initial =
                refresh_watch_snapshot(&mut snapshot, &BTreeSet::new(), RefreshScope::Full)
                    .expect("initial snapshot");
            assert!(initial.sessions_updated);
            assert!(initial.session_ids.contains("watch-sess"));

            let signal_dir = runtime::runtime_for_name("codex")
                .expect("codex runtime")
                .signal_dir(project, &worker_session_id);
            acknowledge_signal(
                &signal_dir,
                &SignalAck {
                    signal_id: signal.signal.signal_id,
                    acknowledged_at: "2026-03-28T12:10:00Z".into(),
                    result: AckResult::Accepted,
                    agent: "worker-session".into(),
                    session_id: "watch-sess".into(),
                    details: Some("applied".into()),
                },
            )
            .expect("ack signal");
            let targeted = BTreeSet::from(["watch-sess".to_string()]);
            let changed =
                refresh_watch_snapshot(&mut snapshot, &targeted, RefreshScope::SessionScoped)
                    .expect("changed snapshot");
            assert!(!changed.sessions_updated);
            assert!(changed.session_ids.contains("watch-sess"));
        });
    }
}
