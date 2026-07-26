use std::collections::HashMap;

use crate::daemon::db::TaskBoardItemSnapshot;
use crate::daemon::protocol::{TaskBoardListItemsResponse, TaskBoardListItemsSelection};
use crate::daemon::service::TaskBoardListSource;
use crate::task_board::{
    TaskBoardItem, TaskBoardQueryFields, TaskBoardQueryTarget, select_page,
};
use harness_kernel::errors::{CliError, CliErrorKind};

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

impl TaskBoardQueryTarget for TaskBoardItemSnapshot {
    fn query_fields(&self) -> TaskBoardQueryFields<'_> {
        self.item.query_fields()
    }
}

struct RevisionedItem<T> {
    item: T,
    item_revision: i64,
}

impl<T: TaskBoardQueryTarget> TaskBoardQueryTarget for RevisionedItem<T> {
    fn query_fields(&self) -> TaskBoardQueryFields<'_> {
        self.item.query_fields()
    }
}

/// Select, page, and project one board read for the client that asked for it.
///
/// A remote viewer's selection runs against that viewer's redacted projection
/// rather than the stored items, so a facet or text search can only ever
/// distinguish items by text the same viewer could have read back anyway.
pub(crate) fn project_task_board_list(
    source: TaskBoardListSource,
    selection: &TaskBoardListItemsSelection,
    viewer: bool,
) -> Result<TaskBoardReadListResponse, CliError> {
    let TaskBoardListSource {
        items,
        items_change_seq,
        progress_rollups,
    } = source;
    if viewer {
        let MatchedPage {
            items,
            total_matched,
            next_cursor,
        } = select_matching_page(
            items
                .into_iter()
                .map(|snapshot| RevisionedItem {
                    item: RemoteViewerTaskBoardItem::from(snapshot.item),
                    item_revision: snapshot.item_revision,
                })
                .collect(),
            selection,
            items_change_seq,
        )?;
        let (items, item_revisions) = split_revisioned_page(items);
        return Ok(TaskBoardReadListResponse::Viewer(
            RemoteViewerTaskBoardListResponse {
                items,
                items_change_seq,
                item_revisions,
                total_matched,
                next_cursor,
            },
        ));
    }
    let MatchedPage {
        items,
        total_matched,
        next_cursor,
    } = select_matching_page(items, selection, items_change_seq)?;
    let (items, item_revisions) = split_snapshot_page(items);
    let mut response = TaskBoardListItemsResponse {
        items,
        items_change_seq,
        item_revisions,
        progress_rollups,
        total_matched,
        next_cursor,
    };
    drop_cached_provider_text(&mut response);
    Ok(TaskBoardReadListResponse::Full(response))
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
    items_change_seq: i64,
) -> Result<MatchedPage<T>, CliError> {
    let query = selection.query.prepared();
    let matched = items
        .iter()
        .enumerate()
        .filter_map(|(index, item)| {
            let fields = item.query_fields();
            query.matches(&fields).then_some((index, fields.id))
        })
        .collect::<Vec<_>>();
    let matched_ids = matched.iter().map(|(_, id)| *id).collect::<Vec<_>>();
    let page = select_page(
        &matched_ids,
        selection.cursor.as_ref(),
        selection.limit,
        items_change_seq,
    )
    .ok_or_else(stale_task_board_cursor)?;
    let total_matched = matched.len();
    let window = matched[page.start..page.end]
        .iter()
        .map(|(index, _)| *index)
        .collect::<Vec<_>>();
    Ok(MatchedPage {
        items: page_items(items, &window),
        total_matched,
        next_cursor: page.next_cursor.map(|cursor| cursor.encode()),
    })
}

fn stale_task_board_cursor() -> CliError {
    CliErrorKind::workflow_io(
        "the task-board list cursor is stale because the board changed; restart without a cursor",
    )
    .into()
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

fn split_snapshot_page(
    snapshots: Vec<TaskBoardItemSnapshot>,
) -> (Vec<TaskBoardItem>, HashMap<String, i64>) {
    split_revisioned_page(
        snapshots
            .into_iter()
            .map(|snapshot| RevisionedItem {
                item: snapshot.item,
                item_revision: snapshot.item_revision,
            }),
    )
}

fn split_revisioned_page<T: TaskBoardQueryTarget>(
    entries: impl IntoIterator<Item = RevisionedItem<T>>,
) -> (Vec<T>, HashMap<String, i64>) {
    let entries = entries.into_iter();
    let (minimum, _) = entries.size_hint();
    let mut items = Vec::with_capacity(minimum);
    let mut revisions = HashMap::with_capacity(minimum);
    for entry in entries {
        revisions.insert(
            entry.item.query_fields().id.to_owned(),
            entry.item_revision,
        );
        items.push(entry.item);
    }
    (items, revisions)
}
