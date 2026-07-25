use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;

use super::types::{AgentMode, TaskBoardItem, TaskBoardPriority, TaskBoardStatus};

pub use super::item_query_bounds::{
    TASK_BOARD_LIST_DEFAULT_LIMIT, TASK_BOARD_LIST_MAX_LIMIT, TASK_BOARD_LIST_MAX_QUERY_CHARS,
    TASK_BOARD_LIST_MAX_TAGS,
};

/// The one view of an item a list query is allowed to read.
///
/// A trusted client builds it from the stored item; a remote viewer builds it
/// from that viewer's redacted projection. Matching only ever reads this view,
/// so a viewer's facet or text search can never test text the same viewer is
/// forbidden to read back.
#[derive(Debug, Clone, Copy)]
pub struct TaskBoardQueryFields<'a> {
    pub id: &'a str,
    pub title: &'a str,
    pub body: &'a str,
    pub tags: &'a [String],
    pub status: TaskBoardStatus,
    pub priority: TaskBoardPriority,
    pub agent_mode: AgentMode,
    pub project_id: Option<&'a str>,
}

/// An item shape a list query can be evaluated against.
pub trait TaskBoardQueryTarget {
    fn query_fields(&self) -> TaskBoardQueryFields<'_>;
}

impl TaskBoardQueryTarget for TaskBoardItem {
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

/// A resolved facet and text selection over one board read.
///
/// Every facet names a field the remote-viewer projection keeps, so one
/// selection means the same thing for every client and no facet can probe a
/// field a viewer cannot see.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TaskBoardItemQuery {
    pub status: Option<TaskBoardStatus>,
    pub priority: Option<TaskBoardPriority>,
    pub agent_mode: Option<AgentMode>,
    pub project_id: Option<String>,
    /// An item must carry every one of these tags to match.
    pub tags: Vec<String>,
    /// Substring matched case-insensitively against title, body, and tags.
    pub text: Option<String>,
}

impl TaskBoardItemQuery {
    /// Reduce the query's text and tags to the form matching compares against.
    ///
    /// Scanning a board runs the match once per item, so anything derived from
    /// the query alone is folded in here instead: doing it inside the match
    /// would allocate a fresh needle and a fresh canonical tag for every row.
    #[must_use]
    pub fn prepared(&self) -> PreparedTaskBoardItemQuery<'_> {
        PreparedTaskBoardItemQuery {
            query: self,
            text: self.text.as_deref().map(str::to_lowercase),
            tags: self.tags.iter().map(|tag| canonical_tag(tag)).collect(),
        }
    }
}

/// One query reduced for scanning, borrowed from the selection it came from.
pub struct PreparedTaskBoardItemQuery<'a> {
    query: &'a TaskBoardItemQuery,
    text: Option<String>,
    tags: Vec<String>,
}

impl PreparedTaskBoardItemQuery<'_> {
    #[must_use]
    pub fn matches(&self, fields: &TaskBoardQueryFields<'_>) -> bool {
        self.status_matches(fields.status)
            && self
                .query
                .priority
                .is_none_or(|wanted| wanted == fields.priority)
            && self
                .query
                .agent_mode
                .is_none_or(|wanted| wanted == fields.agent_mode)
            && self
                .query
                .project_id
                .as_deref()
                .is_none_or(|wanted| fields.project_id == Some(wanted))
            && self.tags_match(fields.tags)
            && self.text_matches(fields)
    }

    fn status_matches(&self, status: TaskBoardStatus) -> bool {
        self.query.status.is_none_or(|wanted| {
            wanted.canonical_persisted_status() == status.canonical_persisted_status()
        })
    }

    fn tags_match(&self, tags: &[String]) -> bool {
        self.tags
            .iter()
            .all(|wanted| tags.iter().any(|tag| &canonical_tag(tag) == wanted))
    }

    fn text_matches(&self, fields: &TaskBoardQueryFields<'_>) -> bool {
        let Some(text) = self.text.as_deref() else {
            return true;
        };
        contains_ignoring_case(fields.title, text)
            || contains_ignoring_case(fields.body, text)
            || fields
                .tags
                .iter()
                .any(|tag| contains_ignoring_case(tag, text))
    }
}

/// Where a page resumes: the last item the previous page returned, plus the
/// index it sat at. The id resumes exactly while that item is still matched;
/// the index is the fallback for an item deleted or edited out of the
/// selection between two reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardListCursor {
    pub offset: usize,
    pub item_id: String,
}

impl TaskBoardListCursor {
    #[must_use]
    pub fn encode(&self) -> String {
        URL_SAFE_NO_PAD.encode(format!("{}:{}", self.offset, self.item_id))
    }

    #[must_use]
    pub fn decode(raw: &str) -> Option<Self> {
        let decoded = URL_SAFE_NO_PAD.decode(raw).ok()?;
        let decoded = String::from_utf8(decoded).ok()?;
        let (offset, item_id) = decoded.split_once(':')?;
        if item_id.is_empty() {
            return None;
        }
        Some(Self {
            offset: offset.parse().ok()?,
            item_id: item_id.to_string(),
        })
    }
}

/// One page cut out of a matched, ordered selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardListPage {
    pub start: usize,
    pub end: usize,
    pub next_cursor: Option<TaskBoardListCursor>,
}

/// Cut `limit` items out of an ordered selection, resuming after `cursor`.
///
/// `matched_ids` carries the whole matched selection in response order. Paging
/// a board nobody is mutating never repeats or skips an item: each cursor
/// names the last item handed out, and the next page starts at the one after
/// it.
#[must_use]
pub fn select_page(
    matched_ids: &[&str],
    cursor: Option<&TaskBoardListCursor>,
    limit: u32,
) -> TaskBoardListPage {
    let start = cursor.map_or(0, |cursor| resume_index(matched_ids, cursor));
    let end = start.saturating_add(limit as usize).min(matched_ids.len());
    let next_cursor = (end < matched_ids.len() && end > start).then(|| TaskBoardListCursor {
        offset: end - 1,
        item_id: matched_ids[end - 1].to_string(),
    });
    TaskBoardListPage {
        start,
        end,
        next_cursor,
    }
}

/// Resolve a cursor's anchor to the index the next page starts at.
fn resume_index(matched_ids: &[&str], cursor: &TaskBoardListCursor) -> usize {
    matched_ids
        .iter()
        .position(|id| *id == cursor.item_id)
        .map_or_else(
            // The anchor left the selection, so everything after it shifted
            // down one slot and the first unseen item now sits where the
            // anchor did.
            || cursor.offset.min(matched_ids.len()),
            |index| index.saturating_add(1),
        )
}

/// Resolve a caller's page size, refusing an explicit out-of-range one rather
/// than clamping it, so nobody silently reads a page they did not ask for.
#[must_use]
pub fn validated_limit(limit: Option<u32>) -> Option<u32> {
    match limit {
        Some(limit @ 1..=TASK_BOARD_LIST_MAX_LIMIT) => Some(limit),
        Some(_) => None,
        None => Some(TASK_BOARD_LIST_DEFAULT_LIMIT),
    }
}

/// Reduce free text to the form matching uses, or `None` when it selects
/// nothing.
#[must_use]
pub fn normalize_query_text(text: Option<&str>) -> Option<String> {
    let text = text?.trim();
    (!text.is_empty()).then(|| text.to_string())
}

fn contains_ignoring_case(haystack: &str, needle_lowercase: &str) -> bool {
    haystack.to_lowercase().contains(needle_lowercase)
}

/// Reduce one tag to the form a facet compares, matching what
/// [`canonicalize_labels`](super::triage::canonicalize_labels) does per tag.
/// The write path stores tags exactly as they arrive, so an item really can
/// hold `"backend "`, and comparing either side raw would leave it
/// unmatchable.
fn canonical_tag(tag: &str) -> String {
    tag.trim().to_lowercase()
}

#[cfg(test)]
#[path = "item_query_tests.rs"]
mod tests;
