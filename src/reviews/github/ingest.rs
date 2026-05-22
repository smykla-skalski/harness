use std::collections::{BTreeMap, BTreeSet};

use crate::errors::CliError;

use super::mapping::{NodeContinuation, RepositoryLabelBundle, convert_node};
use super::types::SearchNode;
use super::{ReviewItem, ReviewRepositoryLabel, ReviewsQueryRequest};

pub(super) fn ingest_search_node(
    node: SearchNode,
    request: &ReviewsQueryRequest,
    deduped: &mut BTreeMap<String, ReviewItem>,
    continuations: &mut BTreeMap<String, NodeContinuation>,
    repository_labels: &mut BTreeMap<String, Vec<ReviewRepositoryLabel>>,
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
    items: &mut Vec<ReviewItem>,
    continuations: &mut Vec<NodeContinuation>,
    missing: &mut Vec<String>,
    repository_labels: &mut BTreeMap<String, Vec<ReviewRepositoryLabel>>,
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
    repository_labels: &mut BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    bundle: RepositoryLabelBundle,
) {
    let (repository, labels) = bundle;
    if labels.is_empty() {
        return;
    }
    let entry = repository_labels.entry(repository).or_default();
    if entry.is_empty() {
        *entry = labels;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_label(name: &str) -> ReviewRepositoryLabel {
        ReviewRepositoryLabel {
            name: name.to_string(),
            color: None,
            description: None,
        }
    }

    #[test]
    fn empty_bundle_does_not_insert_repository_key() {
        let mut map: BTreeMap<String, Vec<ReviewRepositoryLabel>> = BTreeMap::new();
        merge_repository_label_bundle(&mut map, ("acme/api".to_string(), Vec::new()));
        assert!(
            map.is_empty(),
            "empty bundle must not create a repository entry"
        );
    }

    #[test]
    fn empty_bundle_preserves_existing_non_empty_entry() {
        let mut map: BTreeMap<String, Vec<ReviewRepositoryLabel>> = BTreeMap::new();
        map.insert("acme/api".to_string(), vec![make_label("bug")]);
        merge_repository_label_bundle(&mut map, ("acme/api".to_string(), Vec::new()));
        assert_eq!(map.get("acme/api").map(Vec::len), Some(1));
    }

    #[test]
    fn first_non_empty_bundle_fills_entry() {
        let mut map: BTreeMap<String, Vec<ReviewRepositoryLabel>> = BTreeMap::new();
        merge_repository_label_bundle(&mut map, ("acme/api".to_string(), vec![make_label("bug")]));
        assert_eq!(
            map.get("acme/api").map(|labels| labels[0].name.clone()),
            Some("bug".to_string())
        );
    }

    #[test]
    fn subsequent_non_empty_bundle_does_not_overwrite_filled_entry() {
        let mut map: BTreeMap<String, Vec<ReviewRepositoryLabel>> = BTreeMap::new();
        merge_repository_label_bundle(&mut map, ("acme/api".to_string(), vec![make_label("bug")]));
        merge_repository_label_bundle(&mut map, ("acme/api".to_string(), vec![make_label("ci")]));
        assert_eq!(
            map.get("acme/api").map(|labels| labels[0].name.clone()),
            Some("bug".to_string())
        );
    }
}
