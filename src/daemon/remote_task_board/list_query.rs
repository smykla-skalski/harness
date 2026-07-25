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

/// Match, then keep only the page's items.
///
/// The board read that feeds this already holds every live item, because both
/// the roll-ups and the canonical lane order need the whole set. Selection
/// therefore walks that set by index and moves out only the items the page
/// returns, rather than materializing the matched selection a second time.
fn select_matching_page<T: TaskBoardQueryTarget>(
    items: Vec<T>,
    selection: &TaskBoardListItemsSelection,
) -> MatchedPage<T> {
    let matched = items
        .iter()
        .enumerate()
        .filter(|(_, item)| selection.query.matches(&item.query_fields()))
        .map(|(index, item)| (index, item.query_fields().id))
        .collect::<Vec<_>>();
    let matched_ids = matched.iter().map(|(_, id)| *id).collect::<Vec<_>>();
    let page = select_page(&matched_ids, selection.cursor.as_ref(), selection.limit);
    let total_matched = matched.len();
    let window = matched[page.start..page.end]
        .iter()
        .map(|(index, _)| *index)
        .collect::<Vec<_>>();
    MatchedPage {
        items: page_items(items, &window),
        total_matched,
        next_cursor: page.next_cursor.map(|cursor| cursor.encode()),
    }
}

/// Move out the items at `window`, which is ascending, and drop the rest.
fn page_items<T>(items: Vec<T>, window: &[usize]) -> Vec<T> {
    let mut wanted = window.iter().copied().peekable();
    items
        .into_iter()
        .enumerate()
        .filter_map(|(index, item)| {
            (wanted.next_if(|next| *next == index).is_some()).then_some(item)
        })
        .collect()
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
