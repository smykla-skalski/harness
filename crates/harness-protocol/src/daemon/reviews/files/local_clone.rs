//! Just the local bare-clone registry's list-entry DTO. The registry itself
//! (`RepoKey`, `RegistryEntry`, `LocalCloneRegistry`, `LocalCloneRoot`, disk
//! eviction, GC) is real filesystem-backed state and stays in
//! `harness-reviews`; its `local_clone_list_entry_from_registry` free
//! function (moved off this struct's own former inherent `impl` to avoid
//! `harness-protocol` depending back on `harness-reviews` for `RepoKey` /
//! `RegistryEntry`) builds this DTO from that state.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// One row in the Settings-panel projection of the clones registry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct LocalCloneListEntry {
    pub repo_full_name: String,
    pub repo_key_segment: String,
    pub size_bytes: u64,
    #[schema(value_type = String, format = DateTime)]
    pub created_at: DateTime<Utc>,
    #[schema(value_type = String, format = DateTime)]
    pub last_used_at: DateTime<Utc>,
    #[schema(value_type = String, format = DateTime)]
    pub last_fetched_at: DateTime<Utc>,
}
