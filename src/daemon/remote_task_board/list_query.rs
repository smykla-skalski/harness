use std::collections::HashMap;

use crate::daemon::protocol::{TaskBoardListItemsResponse, TaskBoardListItemsSelection};
use crate::daemon::service::TaskBoardListSource;
use crate::task_board::{TaskBoardQueryFields, TaskBoardQueryTarget, select_page};

use super::{
    RemoteViewerTaskBoardItem, RemoteViewerTaskBoardListResponse, TaskBoardReadListResponse,
    drop_cached_provider_text,
};

impl TaskBoardQueryTarget for RemoteViewerTaskBoardItem {
    fn query_fields(&self) -> TaskBoardQueryFields<'_> {
        TaskBoardQueryFields {
            id: &self.id,
            title: &self.title,
            body: &self.body,
            tags: &self.tags,
            status: self.status,
            priority: self.priority,
            agent_mode: self.agent_mode,
            project_id: self.project_id.as_deref(),
        }
    }
}

/// Select, page, and project one board read for the client that asked for it.
///
/// A remote viewer's selection runs against that viewer's redacted projection
/// rather than the stored items, so a facet or text search can only ever
/// distinguish items by text the same viewer could have read back anyway.
#[must_use]
pub(crate) fn project_task_board_list(
    source: TaskBoardListSource,
    selection: &TaskBoardListItemsSelection,
    viewer: bool,
) -> TaskBoardReadListResponse {
    let TaskBoardListSource {
        items,
        items_change_seq,
        item_revisions,
        progress_rollups,
    } = source;
    if viewer {
        let page = select_matching_page(
            items
                .into_iter()
                .map(RemoteViewerTaskBoardItem::from)
                .collect(),
            selection,
        );
        return TaskBoardReadListResponse::Viewer(RemoteViewerTaskBoardListResponse {
            item_revisions: revisions_for_page(&page.items, &item_revisions),
            items: page.items,
            items_change_seq,
            total_matched: page.total_matched,
            next_cursor: page.next_cursor,
        });
    }
    let page = select_matching_page(items, selection);
    let mut response = TaskBoardListItemsResponse {
        item_revisions: revisions_for_page(&page.items, &item_revisions),
        items: page.items,
        items_change_seq,
        progress_rollups,
        total_matched: page.total_matched,
        next_cursor: page.next_cursor,
    };
    drop_cached_provider_text(&mut response);
    TaskBoardReadListResponse::Full(response)
}

struct MatchedPage<T> {
    items: Vec<T>,
    total_matched: usize,
    next_cursor: Option<String>,
}

fn select_matching_page<T: TaskBoardQueryTarget>(
    items: Vec<T>,
    selection: &TaskBoardListItemsSelection,
) -> MatchedPage<T> {
    let matched = items
        .into_iter()
        .filter(|item| selection.query.matches(&item.query_fields()))
        .collect::<Vec<_>>();
    let matched_ids = matched
        .iter()
        .map(|item| item.query_fields().id)
        .collect::<Vec<_>>();
    let page = select_page(&matched_ids, selection.cursor.as_ref(), selection.limit);
    let (start, end) = (page.start, page.end);
    let next_cursor = page.next_cursor.map(|cursor| cursor.encode());
    let total_matched = matched.len();
    MatchedPage {
        items: matched.into_iter().take(end).skip(start).collect(),
        total_matched,
        next_cursor,
    }
}

fn revisions_for_page<T: TaskBoardQueryTarget>(
    items: &[T],
    revisions: &HashMap<String, i64>,
) -> HashMap<String, i64> {
    items
        .iter()
        .filter_map(|item| {
            let id = item.query_fields().id;
            revisions
                .get(id)
                .map(|revision| (id.to_string(), *revision))
        })
        .collect()
}
