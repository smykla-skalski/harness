use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use tokio::spawn;
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;
use tokio::time::{Instant as TokioInstant, interval as tokio_interval, sleep_until};

use super::paths::{
    WatchPathTarget, session_id_from_path_with_cache, watch_target_from_path_with_cache,
};
use super::refresh::{emit_watch_changes, refresh_watch_snapshot};
use super::state::{
    PendingWatchPaths, RefreshScope, RuntimeSessionResolveCache, WatchChanges, WatchSnapshot,
};
use crate::daemon::db::{DaemonDb, session_id_from_change_scope};
use crate::daemon::index;
use crate::daemon::protocol::StreamEvent;

pub(super) const CHANGE_TRACKING_POLL_SQL: &str = "SELECT scope, version, change_seq
     FROM change_tracking
     WHERE change_seq > ?1
     ORDER BY change_seq";

/// Spawn the daemon's refresh loop for SSE/WS subscribers. When a database
/// is available, uses `change_tracking` versions instead of full filesystem
/// discovery. Falls back to the legacy JSON-diff approach otherwise.
#[must_use]
pub fn spawn_watch_loop(
    sender: broadcast::Sender<StreamEvent>,
    interval: Duration,
    db: Option<Arc<Mutex<DaemonDb>>>,
) -> JoinHandle<()> {
    match db {
        Some(db) => spawn_db_watch_loop(sender, interval, db),
        None => spawn_legacy_watch_loop(sender, interval),
    }
}

fn spawn_db_watch_loop(
    sender: broadcast::Sender<StreamEvent>,
    interval: Duration,
    db: Arc<Mutex<DaemonDb>>,
) -> JoinHandle<()> {
    spawn(async move {
        let root = index::projects_root();
        let _ = fs_err::create_dir_all(&root);

        let (event_tx, mut event_rx) = mpsc::channel::<notify::Result<notify::Event>>(128);
        let _watcher = create_watcher(event_tx).and_then(|mut watcher| {
            watcher
                .watch(&root, RecursiveMode::Recursive)
                .ok()
                .map(|()| watcher)
        });

        let mut ticker = tokio_interval(interval);
        let mut last_change_seq: i64 = 0;
        let mut pending_paths = PendingWatchPaths::default();
        let mut resolve_cache = RuntimeSessionResolveCache::default();

        loop {
            let debounce_sleep = pending_paths
                .next_flush_at()
                .map(|deadline| sleep_until(TokioInstant::from_std(deadline)));
            tokio::select! {
                Some(result) = event_rx.recv() => {
                    pending_paths.push_result(result, Instant::now());
                    while let Ok(result) = event_rx.try_recv() {
                        pending_paths.push_result(result, Instant::now());
                    }
                }
                _ = ticker.tick() => {}
                () = async {
                    if let Some(sleep) = debounce_sleep {
                        sleep.await;
                    }
                }, if pending_paths.has_pending() => {}
            }

            if let Some(paths) = pending_paths.take_ready_paths(Instant::now()) {
                reindex_sessions_from_paths(&db, &paths, &mut resolve_cache);
            }

            let Ok(db_guard) = db.lock() else {
                continue;
            };
            let changes = poll_change_tracking(&db_guard, &mut last_change_seq);
            drop(db_guard);

            emit_watch_changes(&sender, changes, Some(&db));
        }
    })
}

fn spawn_legacy_watch_loop(
    sender: broadcast::Sender<StreamEvent>,
    interval: Duration,
) -> JoinHandle<()> {
    spawn(async move {
        let root = index::projects_root();
        let _ = fs_err::create_dir_all(&root);

        let (event_tx, mut event_rx) = mpsc::channel::<notify::Result<notify::Event>>(128);
        let watcher = create_watcher(event_tx).and_then(|mut watcher| {
            watcher
                .watch(&root, RecursiveMode::Recursive)
                .ok()
                .map(|()| watcher)
        });

        let mut ticker = tokio_interval(interval);
        let mut snapshot = WatchSnapshot::default();
        let mut resolve_cache = RuntimeSessionResolveCache::default();
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
                    merge_watch_event(
                        result,
                        &mut targeted_session_ids,
                        &mut scope,
                        &mut resolve_cache,
                    );
                }
                _ = ticker.tick() => {
                    scope = RefreshScope::Full;
                }
            }

            while let Ok(result) = event_rx.try_recv() {
                merge_watch_event(
                    result,
                    &mut targeted_session_ids,
                    &mut scope,
                    &mut resolve_cache,
                );
            }

            let Ok(changes) = refresh_watch_snapshot(&mut snapshot, &targeted_session_ids, scope)
            else {
                continue;
            };
            emit_watch_changes(&sender, changes, None);
        }
    })
}

pub(super) fn poll_change_tracking(db: &DaemonDb, last_change_seq: &mut i64) -> WatchChanges {
    let mut changes = WatchChanges::default();

    let Ok(rows) = db
        .connection()
        .prepare_cached(CHANGE_TRACKING_POLL_SQL)
        .and_then(|mut statement| {
            statement
                .query_map([*last_change_seq], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                })
                .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        })
    else {
        return changes;
    };

    for (scope, _version, change_seq) in rows {
        *last_change_seq = change_seq;
        if scope == "global" {
            changes.sessions_updated = true;
        } else if let Some(session_id) = session_id_from_change_scope(&scope) {
            changes.session_ids.insert(session_id.to_string());
        }
    }

    changes
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn reindex_sessions_from_paths(
    db: &Arc<Mutex<DaemonDb>>,
    paths: &[PathBuf],
    resolve_cache: &mut RuntimeSessionResolveCache,
) {
    resolve_cache.invalidate_paths(paths);
    let work = extract_reindex_work(paths, resolve_cache);
    if work.full_session_ids.is_empty() && work.transcript_targets.is_empty() {
        return;
    }
    tracing::debug!(
        full_count = work.full_session_ids.len(),
        transcript_count = work.transcript_targets.len(),
        "reindexing sessions from file events"
    );
    let start = Instant::now();
    let prepare_start = Instant::now();
    let mut prepared_sessions = Vec::new();
    let mut prepared_transcripts = Vec::new();
    let mut fallback_session_ids = work.full_session_ids;

    for target in &work.transcript_targets {
        match DaemonDb::prepare_runtime_transcript_resync(
            &target.session_id,
            &target.runtime_name,
            &target.runtime_session_id,
        ) {
            Ok(Some(import)) => prepared_transcripts.push(import),
            Ok(None) => {
                fallback_session_ids.insert(target.session_id.clone());
            }
            Err(error) => {
                tracing::warn!(
                    %error,
                    session_id = target.session_id,
                    runtime_name = target.runtime_name,
                    runtime_session_id = target.runtime_session_id,
                    "failed to prepare targeted transcript reindex; falling back to full session reindex"
                );
                fallback_session_ids.insert(target.session_id.clone());
            }
        }
    }

    for session_id in &fallback_session_ids {
        match DaemonDb::prepare_session_resync(session_id) {
            Ok(import) => prepared_sessions.push(import),
            Err(error) => tracing::warn!(
                %error,
                session_id,
                "failed to prepare session reindex"
            ),
        }
    }
    let prepare_ms = u64::try_from(prepare_start.elapsed().as_millis()).unwrap_or(u64::MAX);
    if prepared_sessions.is_empty() && prepared_transcripts.is_empty() {
        return;
    }

    let apply_start = Instant::now();
    let Ok(db_guard) = db.lock() else {
        return;
    };
    for import in &prepared_sessions {
        if let Err(error) = db_guard.apply_prepared_session_resync(import) {
            tracing::warn!(%error, "failed to apply prepared session reindex");
        }
    }
    for import in &prepared_transcripts {
        if let Err(error) = db_guard.apply_prepared_runtime_transcript_resync(import) {
            tracing::warn!(%error, "failed to apply prepared transcript reindex");
        }
    }
    let apply_ms = u64::try_from(apply_start.elapsed().as_millis()).unwrap_or(u64::MAX);
    let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    tracing::debug!(
        duration_ms,
        prepare_ms,
        apply_ms,
        full_count = prepared_sessions.len(),
        transcript_count = prepared_transcripts.len(),
        "reindex complete"
    );
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct TranscriptRefreshTarget {
    session_id: String,
    runtime_name: String,
    runtime_session_id: String,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct ReindexWork {
    full_session_ids: BTreeSet<String>,
    transcript_targets: BTreeSet<TranscriptRefreshTarget>,
}

fn extract_reindex_work(
    paths: &[PathBuf],
    resolve_cache: &mut RuntimeSessionResolveCache,
) -> ReindexWork {
    let mut work = ReindexWork::default();

    for path in paths {
        match watch_target_from_path_with_cache(path, resolve_cache)
            .ok()
            .flatten()
        {
            Some(WatchPathTarget::Session(session_id)) => {
                work.full_session_ids.insert(session_id);
            }
            Some(WatchPathTarget::Transcript {
                session_id,
                runtime_name,
                runtime_session_id,
            }) => {
                work.transcript_targets.insert(TranscriptRefreshTarget {
                    session_id,
                    runtime_name,
                    runtime_session_id,
                });
            }
            None => {}
        }
    }

    work.transcript_targets
        .retain(|target| !work.full_session_ids.contains(&target.session_id));
    work
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
    resolve_cache: &mut RuntimeSessionResolveCache,
) {
    let Ok(event) = result else {
        *scope = RefreshScope::Full;
        return;
    };

    resolve_cache.invalidate_paths(&event.paths);
    let extracted = extract_session_ids(&event.paths, resolve_cache);
    if extracted.is_empty() {
        *scope = RefreshScope::Full;
        return;
    }

    targeted_session_ids.extend(extracted);
}

fn extract_session_ids(
    paths: &[PathBuf],
    resolve_cache: &mut RuntimeSessionResolveCache,
) -> BTreeSet<String> {
    paths
        .iter()
        .filter_map(|path| {
            session_id_from_path_with_cache(path, resolve_cache)
                .ok()
                .flatten()
        })
        .collect()
}
