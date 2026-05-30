//! Process-global cache of the active policy graph for the synchronous
//! action-gating callers.
//!
//! The database is the source of truth for policy canvases; this cache is a
//! lock-free, read-through projection of each root's active canvas document. It
//! is swapped after every policy write (through `PolicyCanvasWorkspaceStore`)
//! and, once the daemon warms it on start, the allow/deny hot path becomes an
//! atomic pointer load instead of a disk read plus a full-graph
//! deserialization.
//!
//! The map is keyed by policy root so concurrent tests with distinct roots
//! never observe each other's writes, mirroring the path-keyed
//! `task_board::store::parse_cache::BOARD_PARSE_CACHE` idiom.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};

use arc_swap::ArcSwap;

use super::PolicyGraph;

type GatePolicyMap = HashMap<PathBuf, Arc<PolicyGraph>>;

static ACTIVE_GATE_POLICY: LazyLock<ArcSwap<GatePolicyMap>> =
    LazyLock::new(|| ArcSwap::from_pointee(GatePolicyMap::new()));

/// Load the cached active gating policy for `root`, if the cache holds one.
///
/// A lock-free atomic load plus a `HashMap` lookup and an `Arc` clone: no disk
/// access and no deserialization. Returns `None` until the root is first
/// populated by a write or the startup warm.
#[must_use]
pub(crate) fn cached_gate_policy(root: &Path) -> Option<Arc<PolicyGraph>> {
    ACTIVE_GATE_POLICY.load().get(root).cloned()
}

/// Swap the cached active gating policy for `root`, inserting `document` or
/// clearing the entry when `None`.
///
/// Called after each successful policy write/promotion and at daemon startup.
/// The swap is atomic; concurrent gating reads observe either the previous or
/// the new graph, never a torn value.
pub(crate) fn store_gate_policy(root: &Path, document: Option<PolicyGraph>) {
    let entry = document.map(Arc::new);
    ACTIVE_GATE_POLICY.rcu(|current| {
        let mut next = current.as_ref().clone();
        match &entry {
            Some(document) => {
                next.insert(root.to_path_buf(), Arc::clone(document));
            }
            None => {
                next.remove(root);
            }
        }
        next
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(tag: &str) -> PathBuf {
        PathBuf::from(format!("/harness-gate-cache-test/{tag}"))
    }

    #[test]
    fn cold_cache_returns_none() {
        assert!(cached_gate_policy(&key("cold")).is_none());
    }

    #[test]
    fn store_then_load_round_trips() {
        let root = key("round-trip");
        store_gate_policy(&root, Some(PolicyGraph::seeded_v2()));
        let cached = cached_gate_policy(&root).expect("policy cached");
        assert_eq!(cached.as_ref(), &PolicyGraph::seeded_v2());
        store_gate_policy(&root, None);
        assert!(cached_gate_policy(&root).is_none());
    }

    #[test]
    fn distinct_roots_do_not_collide() {
        let a = key("iso-a");
        let b = key("iso-b");
        store_gate_policy(&a, Some(PolicyGraph::seeded_v2()));
        assert!(cached_gate_policy(&a).is_some());
        assert!(cached_gate_policy(&b).is_none());
        store_gate_policy(&a, None);
    }
}
