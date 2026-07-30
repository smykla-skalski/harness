use std::path::PathBuf;
use std::time::{Duration, Instant};

use super::state::PendingWatchPaths;

#[test]
fn pending_watch_paths_flushes_after_quiet_period() {
    let base = Instant::now();
    let mut pending = PendingWatchPaths::default();
    pending.push_paths(vec![PathBuf::from("/tmp/watch-1")], base);
    pending.push_paths(
        vec![PathBuf::from("/tmp/watch-2")],
        base + Duration::from_millis(125),
    );

    assert!(
        pending
            .take_ready_paths(base + Duration::from_millis(374))
            .is_none(),
        "batch should stay open until the debounce window after the last event"
    );

    let paths = pending
        .take_ready_paths(base + Duration::from_millis(375))
        .expect("batched paths");
    assert_eq!(
        paths,
        vec![PathBuf::from("/tmp/watch-1"), PathBuf::from("/tmp/watch-2")]
    );
    assert!(
        !pending.has_pending(),
        "flush should reset the pending batch"
    );
}

#[test]
fn pending_watch_paths_flushes_at_max_batch_window() {
    let base = Instant::now();
    let mut pending = PendingWatchPaths::default();
    pending.push_paths(vec![PathBuf::from("/tmp/watch-1")], base);
    pending.push_paths(
        vec![PathBuf::from("/tmp/watch-2")],
        base + Duration::from_millis(200),
    );
    pending.push_paths(
        vec![PathBuf::from("/tmp/watch-3")],
        base + Duration::from_millis(400),
    );
    pending.push_paths(
        vec![PathBuf::from("/tmp/watch-4")],
        base + Duration::from_millis(800),
    );

    assert!(
        pending
            .take_ready_paths(base + Duration::from_millis(999))
            .is_none(),
        "batch should remain pending until the max window expires"
    );

    let paths = pending
        .take_ready_paths(base + Duration::from_secs(1))
        .expect("forced batch flush");
    assert_eq!(paths.len(), 4);
    assert!(
        !pending.has_pending(),
        "forced flush should reset the batch"
    );
}
