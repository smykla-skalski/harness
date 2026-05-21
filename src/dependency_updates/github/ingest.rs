use std::collections::{BTreeMap, BTreeSet};

use crate::errors::CliError;

use super::mapping::{convert_node, NodeContinuation, RepositoryLabelBundle};
use super::types::SearchNode;
use super::{DependencyUpdateItem, DependencyUpdateRepositoryLabel, DependencyUpdatesQueryRequest};

pub(super) fn ingest_search_node(
    node: SearchNode,
    request: &DependencyUpdatesQueryRequest,
    deduped: &mut BTreeMap<String, DependencyUpdateItem>,
    continuations: &mut BTreeMap<String, NodeContinuation>,
    repository_labels: &mut BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>>,
    repository_label_continuation_seen: &mut BTreeSet<String>,
) -> Result<(), CliError> {
    let (item, bundle, mut continuation) = convert_node(node)?;
    if request
        .normalized_exclude_repositories()
        .contains(&item.repository)
    {
        return Ok(());
    }
    if let Some(bundle) = bundle {
        merge_repository_label_bundle(repository_labels, bundle);
    }
    if continuation.repository_labels.is_some()
        && !repository_label_continuation_seen.insert(continuation.repository_id.clone())
    {
        continuation.repository_labels = None;
    }
    let key = format!("{}#{}", item.repository, item.number);
    if continuation.has_work() && !continuations.contains_key(&key) {
        continuations.insert(key.clone(), continuation);
    }
    deduped.insert(key, item);
    Ok(())
}

pub(super) fn ingest_nodes_chunk(
    nodes: Vec<Option<SearchNode>>,
    chunk: &[String],
    items: &mut Vec<DependencyUpdateItem>,
    continuations: &mut Vec<NodeContinuation>,
    missing: &mut Vec<String>,
    repository_labels: &mut BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>>,
    repository_label_continuation_seen: &mut BTreeSet<String>,
) -> Result<(), CliError> {
    for (offset, node) in nodes.into_iter().enumerate() {
        let Some(node) = node else {
            if let Some(id) = chunk.get(offset) {
                missing.push(id.clone());
            }
            continue;
        };
        let (item, bundle, mut continuation) = convert_node(node)?;
        if let Some(bundle) = bundle {
            merge_repository_label_bundle(repository_labels, bundle);
        }
        if continuation.repository_labels.is_some()
            && !repository_label_continuation_seen.insert(continuation.repository_id.clone())
        {
            continuation.repository_labels = None;
        }
        if continuation.has_work() {
            continuations.push(continuation);
        }
        items.push(item);
    }
    Ok(())
}

pub(super) fn merge_repository_label_bundle(
    repository_labels: &mut BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>>,
    bundle: RepositoryLabelBundle,
) {
    let (repository, labels) = bundle;
    let entry = repository_labels.entry(repository).or_default();
    if entry.is_empty() && !labels.is_empty() {
        *entry = labels;
    }
}
