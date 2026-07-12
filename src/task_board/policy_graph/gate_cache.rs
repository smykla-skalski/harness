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
use std::ops::Deref;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};

use arc_swap::ArcSwap;

use super::PolicyGraph;

/// A cached active gating policy plus the identity of the canvas it came from.
///
/// The synchronous gate reads the document to decide allow/deny; the recording
/// seam reads `canvas_id` to stamp each decision with its provenance. The type
/// derefs to the document so existing gating callers read the graph unchanged.
#[derive(Debug)]
pub(crate) struct CachedGatePolicy {
    pub canvas_id: Option<String>,
    pub document: PolicyGraph,
}

impl CachedGatePolicy {
    /// Build a cached entry tagged with the originating canvas id.
    pub(crate) fn for_canvas(canvas_id: impl Into<String>, document: PolicyGraph) -> Self {
        Self {
            canvas_id: Some(canvas_id.into()),
            document,
        }
    }
}

impl Deref for CachedGatePolicy {
    type Target = PolicyGraph;

    fn deref(&self) -> &PolicyGraph {
        &self.document
    }
}

type GatePolicyMap = HashMap<PathBuf, Arc<CachedGatePolicy>>;

static ACTIVE_GATE_POLICY: LazyLock<ArcSwap<GatePolicyMap>> =
    LazyLock::new(|| ArcSwap::from_pointee(GatePolicyMap::new()));

fn database_policy_key() -> &'static Path {
    Path::new("__harness_database_policy__")
}

/// Load the cached active gating policy for `root`, if the cache holds one.
///
/// A lock-free atomic load plus a `HashMap` lookup and an `Arc` clone: no disk
/// access and no deserialization. Returns `None` until the root is first
/// populated by a write or the startup warm.
#[must_use]
pub(crate) fn cached_gate_policy(root: &Path) -> Option<Arc<CachedGatePolicy>> {
    ACTIVE_GATE_POLICY.load().get(root).cloned()
}

/// Load the daemon database's active policy projection without using a board
/// filesystem path as an identity key.
#[must_use]
#[cfg(test)]
pub(crate) fn cached_database_gate_policy() -> Option<Arc<CachedGatePolicy>> {
    cached_gate_policy(database_policy_key())
}

/// Test-only convenience: cache a bare gating policy with no canvas identity.
///
/// Production write paths use [`store_gate_policy_entry`] so the recording seam
/// can stamp each decision with the canvas it came from; tests that only
/// exercise allow/deny do not care about provenance and set a bare graph.
#[cfg(test)]
pub(crate) fn store_gate_policy(root: &Path, document: Option<PolicyGraph>) {
    store_gate_policy_entry(
        root,
        document.map(|document| CachedGatePolicy {
            canvas_id: None,
            document,
        }),
    );
}

/// Swap the cached gating entry for `root`, carrying the canvas identity so the
/// recording seam can stamp decision provenance. Inserts `entry` or clears the
/// root when `None`. The swap is atomic; concurrent reads never see a torn value.
pub(crate) fn store_gate_policy_entry(root: &Path, entry: Option<CachedGatePolicy>) {
    let entry = entry.map(Arc::new);
    ACTIVE_GATE_POLICY.rcu(|current| {
        let mut next = current.as_ref().clone();
        match &entry {
            Some(entry) => {
                next.insert(root.to_path_buf(), Arc::clone(entry));
            }
            None => {
                next.remove(root);
            }
        }
        next
    });
}

/// Refresh the daemon database's active policy projection.
pub(crate) fn store_database_gate_policy_entry(entry: Option<CachedGatePolicy>) {
    store_gate_policy_entry(database_policy_key(), entry);
}

/// Resolve the active gating policy for `root`: the warm process cache when
/// present, otherwise a cold read from the durable store. The cold read does
/// not populate the cache; the policy write path keeps the cache current.
#[cfg(test)]
pub(crate) fn resolve_gate_policy(root: &Path) -> Option<Arc<CachedGatePolicy>> {
    cached_gate_policy(root)
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
        assert_eq!(cached.document, PolicyGraph::seeded_v2());
        assert!(cached.canvas_id.is_none());
        store_gate_policy(&root, None);
        assert!(cached_gate_policy(&root).is_none());
    }

    #[test]
    fn entry_round_trips_canvas_id() {
        let root = key("entry-canvas");
        store_gate_policy_entry(
            &root,
            Some(CachedGatePolicy::for_canvas(
                "canvas-9",
                PolicyGraph::seeded_v2(),
            )),
        );
        let cached = cached_gate_policy(&root).expect("entry cached");
        assert_eq!(cached.canvas_id.as_deref(), Some("canvas-9"));
        assert_eq!(cached.document, PolicyGraph::seeded_v2());
        // Deref keeps gating reads working through the wrapper.
        assert_eq!(cached.mode, PolicyGraph::seeded_v2().mode);
        store_gate_policy(&root, None);
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

    #[test]
    fn database_projection_does_not_alias_a_legacy_root() {
        let root = key("database-isolation");
        store_gate_policy(&root, Some(PolicyGraph::seeded_v2()));
        store_database_gate_policy_entry(None);
        assert!(cached_database_gate_policy().is_none());

        store_database_gate_policy_entry(Some(CachedGatePolicy::for_canvas(
            "canvas-db",
            PolicyGraph::seeded_v2(),
        )));
        assert_eq!(
            cached_database_gate_policy()
                .expect("database policy cached")
                .canvas_id
                .as_deref(),
            Some("canvas-db")
        );
        store_database_gate_policy_entry(None);
        store_gate_policy(&root, None);
    }
}
