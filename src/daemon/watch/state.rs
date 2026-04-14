use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::mem;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::errors::CliError;

use super::paths::orchestration_context_root;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct SessionDigest {
    pub(super) detail_json: String,
    pub(super) timeline_json: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct WatchSnapshot {
    pub(super) sessions_json: String,
    pub(super) digests: BTreeMap<String, SessionDigest>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct WatchChanges {
    pub(super) sessions_updated: bool,
    pub(super) session_ids: BTreeSet<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RefreshScope {
    SessionScoped,
    Full,
}

pub(super) const DB_WATCH_EVENT_DEBOUNCE: Duration = Duration::from_millis(250);
pub(super) const DB_WATCH_MAX_BATCH_WINDOW: Duration = Duration::from_secs(1);

#[derive(Debug, Default)]
pub(super) struct PendingWatchPaths {
    paths: Vec<PathBuf>,
    first_event_at: Option<Instant>,
    last_event_at: Option<Instant>,
}

impl PendingWatchPaths {
    pub(super) fn has_pending(&self) -> bool {
        !self.paths.is_empty()
    }

    pub(super) fn push_result(&mut self, result: notify::Result<notify::Event>, now: Instant) {
        if let Ok(event) = result {
            self.push_paths(event.paths, now);
        }
    }

    pub(super) fn push_paths(&mut self, mut paths: Vec<PathBuf>, now: Instant) {
        if paths.is_empty() {
            return;
        }

        if self.first_event_at.is_none() {
            self.first_event_at = Some(now);
        }
        self.last_event_at = Some(now);
        self.paths.append(&mut paths);
    }

    pub(super) fn next_flush_at(&self) -> Option<Instant> {
        let first_event_at = self.first_event_at?;
        let last_event_at = self.last_event_at?;
        Some(
            (last_event_at + DB_WATCH_EVENT_DEBOUNCE)
                .min(first_event_at + DB_WATCH_MAX_BATCH_WINDOW),
        )
    }

    pub(super) fn take_ready_paths(&mut self, now: Instant) -> Option<Vec<PathBuf>> {
        let flush_at = self.next_flush_at()?;
        if now < flush_at {
            return None;
        }
        self.take_all()
    }

    fn take_all(&mut self) -> Option<Vec<PathBuf>> {
        if self.paths.is_empty() {
            self.first_event_at = None;
            self.last_event_at = None;
            return None;
        }

        let paths = mem::take(&mut self.paths);
        self.first_event_at = None;
        self.last_event_at = None;
        Some(paths)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(super) struct RuntimeSessionTarget {
    pub(super) context_root: PathBuf,
    pub(super) runtime_name: String,
    pub(super) runtime_session_id: String,
}

#[derive(Debug, Default)]
pub(super) struct RuntimeSessionResolveCache {
    session_ids: HashMap<RuntimeSessionTarget, String>,
}

impl RuntimeSessionResolveCache {
    pub(super) fn invalidate_paths(&mut self, paths: &[PathBuf]) {
        if self.session_ids.is_empty() {
            return;
        }

        let invalidated_contexts: BTreeSet<_> = paths
            .iter()
            .filter_map(|path| orchestration_context_root(path))
            .collect();
        if invalidated_contexts.is_empty() {
            return;
        }

        self.session_ids
            .retain(|target, _| !invalidated_contexts.contains(&target.context_root));
    }

    pub(super) fn resolve_with<F>(
        &mut self,
        target: RuntimeSessionTarget,
        resolver: &mut F,
    ) -> Result<Option<String>, CliError>
    where
        F: FnMut(&Path, &str, &str) -> Result<Option<String>, CliError>,
    {
        if let Some(session_id) = self.session_ids.get(&target) {
            return Ok(Some(session_id.clone()));
        }

        let resolved_session = resolver(
            &target.context_root,
            &target.runtime_name,
            &target.runtime_session_id,
        )?;
        if let Some(session_id) = resolved_session.as_ref() {
            self.session_ids.insert(target, session_id.clone());
        }
        Ok(resolved_session)
    }
}
