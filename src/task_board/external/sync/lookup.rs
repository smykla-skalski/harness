use std::collections::HashMap;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::TaskBoardSyncItemSnapshot;
use crate::task_board::types::{ExternalRefProvider, TaskBoardItem, TaskBoardTombstoneCause};

use super::{
    ExternalProvider, ExternalSyncAction, ExternalSyncField, ExternalSyncOperation, ExternalTask,
    ExternalTaskRef,
};

type ProviderRefKey = (ExternalRefProvider, String);

/// `Ambiguous` means two distinct items claimed this key; resolving it must
/// fail closed rather than pick one.
enum KeyClaim {
    Unique {
        snapshot_index: usize,
        class: SnapshotClass,
    },
    Ambiguous,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SnapshotClass {
    Active,
    Excluded,
}

/// Built once per pull from the batch-loaded snapshot list. Keys map into
/// `snapshots` by index rather than storing a clone per key, so an item with
/// many ref aliases costs one clone. A key two items collide on is not
/// rejected at build time -- that would fail the whole batch over one
/// unrelated alias -- it's marked `Ambiguous` and only fails the query that
/// resolves through it.
pub(super) struct ProviderItemIndex {
    snapshots: Vec<TaskBoardSyncItemSnapshot>,
    claims: HashMap<ProviderRefKey, KeyClaim>,
}

impl ProviderItemIndex {
    pub(super) fn build(snapshots: Vec<TaskBoardSyncItemSnapshot>) -> Self {
        let mut stored = Vec::with_capacity(snapshots.len());
        let mut claims = HashMap::new();
        for snapshot in snapshots {
            let is_excluded = snapshot.item.is_deleted()
                && snapshot.item.tombstone_cause
                    == Some(TaskBoardTombstoneCause::ProviderExclusion);
            if snapshot.item.is_deleted() && !is_excluded {
                continue;
            }
            let index = stored.len();
            let class = if is_excluded {
                SnapshotClass::Excluded
            } else {
                SnapshotClass::Active
            };
            for key in reference_keys(&snapshot.item) {
                claim(&mut claims, key, index, class);
            }
            stored.push(snapshot);
        }
        Self {
            snapshots: stored,
            claims,
        }
    }

    pub(super) fn active_snapshot(
        &self,
        reference: &ExternalTaskRef,
        project_id: Option<&str>,
    ) -> Result<Option<&TaskBoardSyncItemSnapshot>, CliError> {
        self.lookup(SnapshotClass::Active, reference, project_id)
    }

    pub(super) fn excluded_snapshot(
        &self,
        reference: &ExternalTaskRef,
        project_id: Option<&str>,
    ) -> Result<Option<&TaskBoardSyncItemSnapshot>, CliError> {
        self.lookup(SnapshotClass::Excluded, reference, project_id)
    }

    fn lookup(
        &self,
        class: SnapshotClass,
        reference: &ExternalTaskRef,
        project_id: Option<&str>,
    ) -> Result<Option<&TaskBoardSyncItemSnapshot>, CliError> {
        let provider = reference.provider.into();
        let canonical_key = canonical_reference_key(provider, &reference.external_id);
        let canonical_claim = self.claims.get(&(provider, canonical_key.clone()));
        if provider == ExternalRefProvider::GitHub
            && let Some(project) = project_id
        {
            let alias = qualified_alias_key(project, legacy_suffix(&reference.external_id));
            if alias != canonical_key
                && let Some(alias_claim) = self.claims.get(&(provider, alias.clone()))
            {
                return self.resolve_preferred_claim(alias_claim, canonical_claim, class, &alias);
            }
        }
        match canonical_claim {
            Some(claim) => self.resolve_claim(claim, class, &reference.external_id),
            None => Ok(None),
        }
    }

    fn resolve_preferred_claim(
        &self,
        preferred: &KeyClaim,
        fallback: Option<&KeyClaim>,
        class: SnapshotClass,
        key_label: &str,
    ) -> Result<Option<&TaskBoardSyncItemSnapshot>, CliError> {
        let KeyClaim::Unique {
            snapshot_index: preferred_index,
            ..
        } = preferred
        else {
            return self.resolve_claim(preferred, class, key_label);
        };
        if let Some(KeyClaim::Unique {
            snapshot_index: fallback_index,
            ..
        }) = fallback
            && fallback_index != preferred_index
        {
            return Err(CliErrorKind::workflow_io(format!(
                "ambiguous provider reference '{key_label}': exact and project-qualified claims disagree"
            ))
            .into());
        }
        self.resolve_claim(preferred, class, key_label)
    }

    fn resolve_claim(
        &self,
        claim: &KeyClaim,
        class: SnapshotClass,
        key_label: &str,
    ) -> Result<Option<&TaskBoardSyncItemSnapshot>, CliError> {
        match claim {
            KeyClaim::Unique {
                snapshot_index,
                class: claim_class,
            } if *claim_class == class => Ok(self.snapshots.get(*snapshot_index)),
            KeyClaim::Unique { .. } => Ok(None),
            KeyClaim::Ambiguous => Err(CliErrorKind::workflow_io(format!(
                "ambiguous provider reference '{key_label}': more than one item claims it"
            ))
            .into()),
        }
    }
}

fn claim(
    claims: &mut HashMap<ProviderRefKey, KeyClaim>,
    key: ProviderRefKey,
    snapshot_index: usize,
    class: SnapshotClass,
) {
    use std::collections::hash_map::Entry;
    match claims.entry(key) {
        Entry::Vacant(entry) => {
            entry.insert(KeyClaim::Unique {
                snapshot_index,
                class,
            });
        }
        Entry::Occupied(entry)
            if matches!(
                entry.get(),
                KeyClaim::Unique {
                    snapshot_index: existing,
                    ..
                } if *existing == snapshot_index
            ) => {}
        Entry::Occupied(mut entry) => {
            entry.insert(KeyClaim::Ambiguous);
        }
    }
}

/// The bare id portion of a GitHub reference regardless of whether it
/// already carries a cross-repo qualifier.
fn legacy_suffix(external_id: &str) -> &str {
    external_id
        .rsplit_once('#')
        .map_or(external_id, |(_, suffix)| suffix)
}

/// Case-insensitive on the project segment, matching `project_matches`;
/// the id segment stays as-is.
fn qualified_alias_key(project: &str, legacy_id: &str) -> String {
    format!("{}#{legacy_id}", project.to_ascii_lowercase())
}

fn canonical_reference_key(provider: ExternalRefProvider, external_id: &str) -> String {
    if provider == ExternalRefProvider::GitHub
        && let Some((project, legacy_id)) = external_id.rsplit_once('#')
        && !project.is_empty()
    {
        return qualified_alias_key(project, legacy_id);
    }
    external_id.to_string()
}

fn reference_keys(item: &TaskBoardItem) -> Vec<ProviderRefKey> {
    let mut keys = Vec::new();
    for reference in &item.external_refs {
        keys.push((
            reference.provider,
            canonical_reference_key(reference.provider, &reference.external_id),
        ));
        if reference.provider == ExternalRefProvider::GitHub && !reference.external_id.contains('#')
        {
            // A bare legacy id only disambiguates once qualified with the
            // first project candidate the matcher would consult, so a new-
            // format incoming reference ("owner/repo#123") finds this
            // candidate through the plain (provider, external_id) lookup
            // without widening alias ownership to every fallback project.
            if let Some(project) = item
                .execution_repository
                .as_deref()
                .or_else(|| {
                    reference
                        .sync_state
                        .as_ref()
                        .and_then(|state| state.project_id.as_deref())
                })
                .or(item.project_id.as_deref())
            {
                keys.push((
                    reference.provider,
                    qualified_alias_key(project, &reference.external_id),
                ));
            }
        }
    }
    keys
}

/// Resolves the tracking issue a task names as its parent to an already
/// imported local item. Absence is not an error: the parent may not have
/// been imported yet, and the same lookup on a later sync links it up. An
/// ambiguous parent reference is treated the same way rather than failing
/// the child task over it.
pub(super) fn resolve_parent_item_id(
    index: &ProviderItemIndex,
    task: &ExternalTask,
) -> Option<String> {
    let reference = task.parent_reference.as_ref()?;
    // The legacy cross-repo fallback needs the *parent's* repository, which
    // for a cross-repo reference differs from the child's own task.project_id.
    let parent_project_id = reference
        .external_id
        .rsplit_once('#')
        .map(|(project_id, _)| project_id)
        .filter(|project_id| !project_id.is_empty())
        .or(task.project_id.as_deref());
    index
        .active_snapshot(reference, parent_project_id)
        .ok()
        .flatten()
        .map(|snapshot| snapshot.item.id.clone())
}

pub(super) fn provider_ref(
    item: &TaskBoardItem,
    provider: ExternalProvider,
) -> Option<ExternalTaskRef> {
    let core_provider = provider.into();
    item.external_refs
        .iter()
        .filter(|candidate| candidate.provider == core_provider)
        .find_map(|candidate| {
            let probe = ExternalTaskRef::new(provider, candidate.external_id.clone());
            super::matching_ref(item, &probe, item.project_id.as_deref())
                .map(|matched| ExternalTaskRef::from(matched.clone()))
        })
}

pub(super) struct OperationDraft {
    pub(super) provider: ExternalProvider,
    pub(super) action: ExternalSyncAction,
    pub(super) board_item_id: Option<String>,
    pub(super) reference: ExternalTaskRef,
    pub(super) dry_run: bool,
    pub(super) applied: bool,
    pub(super) changed_fields: Vec<ExternalSyncField>,
    pub(super) unsupported_fields: Vec<ExternalSyncField>,
}

pub(super) fn operation(draft: OperationDraft) -> ExternalSyncOperation {
    ExternalSyncOperation {
        provider: draft.provider,
        action: draft.action,
        board_item_id: draft.board_item_id,
        external_id: (!draft.reference.external_id.is_empty())
            .then_some(draft.reference.external_id),
        url: draft.reference.url,
        dry_run: draft.dry_run,
        applied: draft.applied,
        changed_fields: draft.changed_fields,
        unsupported_fields: draft.unsupported_fields,
    }
}

pub(super) fn provider_is_allowed(
    provider: ExternalProvider,
    filter: Option<ExternalProvider>,
) -> bool {
    filter.is_none_or(|target| target == provider)
}

#[cfg(test)]
#[path = "lookup/tests.rs"]
mod tests;
