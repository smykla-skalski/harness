use crate::daemon::protocol::StreamEvent;

/// Cached global `sessions_updated` recovery snapshot keyed by the change
/// generation it was built from. A cache hit requires the live change
/// sequence to still match `change_seq`.
#[derive(Default)]
pub struct RecoverySnapshotCache {
    change_seq: i64,
    sessions_updated: Option<StreamEvent>,
}

impl RecoverySnapshotCache {
    /// Return the cached snapshot when it still matches the live change
    /// generation, else `None` so the caller rebuilds under the held lock.
    #[must_use]
    pub(crate) fn get_fresh(&self, current: i64) -> Option<StreamEvent> {
        if self.change_seq == current {
            self.sessions_updated.clone()
        } else {
            None
        }
    }

    /// Store a freshly built snapshot keyed by the change generation it
    /// reflects.
    pub(crate) fn store(&mut self, current: i64, event: StreamEvent) {
        self.change_seq = current;
        self.sessions_updated = Some(event);
    }
}

#[cfg(test)]
mod tests {
    use super::RecoverySnapshotCache;
    use crate::daemon::protocol::StreamEvent;

    fn sample_event(tag: &str) -> StreamEvent {
        StreamEvent {
            event: "sessions_updated".into(),
            recorded_at: tag.into(),
            session_id: None,
            payload: serde_json::Value::Null,
        }
    }

    #[test]
    fn get_fresh_returns_none_until_a_snapshot_is_stored() {
        let cache = RecoverySnapshotCache::default();
        assert!(cache.get_fresh(0).is_none());
    }

    #[test]
    fn get_fresh_hits_only_on_the_matching_change_generation() {
        let mut cache = RecoverySnapshotCache::default();
        cache.store(7, sample_event("first"));

        assert_eq!(
            cache.get_fresh(7).map(|event| event.recorded_at),
            Some("first".to_string()),
            "snapshot stored at generation 7 must be reused at generation 7"
        );
        assert!(
            cache.get_fresh(8).is_none(),
            "a newer change generation must invalidate the cached snapshot"
        );
    }

    #[test]
    fn store_rekeys_and_replaces_the_previous_snapshot() {
        let mut cache = RecoverySnapshotCache::default();
        cache.store(1, sample_event("old"));
        cache.store(2, sample_event("new"));

        assert!(
            cache.get_fresh(1).is_none(),
            "the superseded generation must no longer hit"
        );
        assert_eq!(
            cache.get_fresh(2).map(|event| event.recorded_at),
            Some("new".to_string())
        );
    }
}
