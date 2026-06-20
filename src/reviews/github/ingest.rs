use std::collections::{BTreeMap, BTreeSet};

use crate::errors::CliError;
use crate::reviews::backports::BackportDetector;

use super::mapping::{NodeContinuation, RepositoryLabelBundle, convert_node};
use super::types::SearchNode;
use super::{ReviewItem, ReviewRepositoryLabel, ReviewsQueryRequest};

pub(super) struct SearchIngestState<'a> {
    pub request: &'a ReviewsQueryRequest,
    pub backport_detector: Option<&'a BackportDetector>,
    pub viewer_login: Option<&'a str>,
    pub deduped: &'a mut BTreeMap<String, ReviewItem>,
    pub continuations: &'a mut BTreeMap<String, NodeContinuation>,
    pub repository_labels: &'a mut BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    pub repository_label_continuation_seen: &'a mut BTreeSet<String>,
}

pub(super) fn ingest_search_node(
    node: SearchNode,
    state: &mut SearchIngestState<'_>,
) -> Result<(), CliError> {
    let (item, bundle, mut continuation) =
        convert_node(node, state.backport_detector, state.viewer_login)?;
    if state
        .request
        .normalized_exclude_repositories()
        .contains(&item.repository)
    {
        return Ok(());
    }
    if let Some(bundle) = bundle {
        merge_repository_label_bundle(state.repository_labels, bundle);
    }
    if continuation.repository_labels.is_some()
        && !state
            .repository_label_continuation_seen
            .insert(continuation.repository_id.clone())
    {
        continuation.repository_labels = None;
    }
    let key = format!("{}#{}", item.repository, item.number);
    if continuation.has_work() && !state.continuations.contains_key(&key) {
        state.continuations.insert(key.clone(), continuation);
    }
    state.deduped.insert(key, item);
    Ok(())
}

#[expect(
    clippy::too_many_arguments,
    reason = "batch ingest merges items, continuations, missing ids, and label caches in one pass"
)]
pub(super) fn ingest_nodes_chunk(
    nodes: Vec<Option<SearchNode>>,
    chunk: &[String],
    backport_detector: Option<&BackportDetector>,
    viewer_login: Option<&str>,
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
        let (item, bundle, mut continuation) = convert_node(node, backport_detector, viewer_login)?;
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
