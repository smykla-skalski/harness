use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use caseless::Caseless as _;

use super::types::{AgentMode, TaskBoardItem, TaskBoardPriority, TaskBoardStatus};

pub use super::item_query_bounds::{
    TASK_BOARD_LIST_DEFAULT_LIMIT, TASK_BOARD_LIST_MAX_CURSOR_CHARS, TASK_BOARD_LIST_MAX_LIMIT,
    TASK_BOARD_LIST_MAX_QUERY_CHARS, TASK_BOARD_LIST_MAX_TAGS,
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
            text: self.text.as_deref().map(FoldedNeedle::new),
            tags: self.tags.iter().map(|tag| canonical_tag(tag)).collect(),
        }
    }
}

/// One query reduced for scanning, borrowed from the selection it came from.
pub struct PreparedTaskBoardItemQuery<'a> {
    query: &'a TaskBoardItemQuery,
    text: Option<FoldedNeedle>,
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
            .all(|wanted| tags.iter().any(|tag| canonical_tag_eq(tag, wanted)))
    }

    fn text_matches(&self, fields: &TaskBoardQueryFields<'_>) -> bool {
        let Some(text) = self.text.as_ref() else {
            return true;
        };
        text.is_contained_in(fields.title)
            || text.is_contained_in(fields.body)
            || fields.tags.iter().any(|tag| text.is_contained_in(tag))
    }
}

const TASK_BOARD_LIST_CURSOR_PREFIX: &str = "v1:";

/// Where a page resumes, bound to the board snapshot that issued it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardListCursor {
    items_change_seq: i64,
    offset: usize,
}

impl TaskBoardListCursor {
    #[must_use]
    pub fn for_page(items_change_seq: i64, offset: usize) -> Self {
        Self {
            items_change_seq,
            offset,
        }
    }

    #[must_use]
    pub fn encode(&self) -> String {
        URL_SAFE_NO_PAD.encode(format!(
            "{TASK_BOARD_LIST_CURSOR_PREFIX}{}:{}",
            self.items_change_seq, self.offset
        ))
    }

    /// Refuses an over-long cursor before decoding it.
    #[must_use]
    pub fn decode(raw: &str) -> Option<Self> {
        if raw.len() > TASK_BOARD_LIST_MAX_CURSOR_CHARS {
            return None;
        }
        let decoded = URL_SAFE_NO_PAD.decode(raw).ok()?;
        let decoded = String::from_utf8(decoded).ok()?;
        let versioned = decoded.strip_prefix(TASK_BOARD_LIST_CURSOR_PREFIX)?;
        let (items_change_seq, offset) = versioned.split_once(':')?;
        Some(Self::for_page(
            items_change_seq.parse().ok()?,
            offset.parse().ok()?,
        ))
    }

    fn matches_change_sequence(&self, items_change_seq: i64) -> bool {
        self.items_change_seq == items_change_seq
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
/// `None` means the cursor does not belong to this selection: either the board
/// changed after it was issued or its offset could not have been emitted for
/// these matches. Refusing either continuation prevents a multi-page read from
/// silently mixing snapshots or treating a forged cursor as a drained board.
#[must_use]
pub fn select_page(
    matched_ids: &[&str],
    cursor: Option<&TaskBoardListCursor>,
    limit: u32,
    items_change_seq: i64,
) -> Option<TaskBoardListPage> {
    if cursor.is_some_and(|cursor| !cursor.matches_change_sequence(items_change_seq)) {
        return None;
    }
    let start = cursor.map_or(Some(0), |cursor| resume_index(matched_ids, cursor))?;
    let end = start.saturating_add(limit as usize).min(matched_ids.len());
    let next_cursor = (end < matched_ids.len() && end > start)
        .then(|| TaskBoardListCursor::for_page(items_change_seq, end - 1));
    Some(TaskBoardListPage {
        start,
        end,
        next_cursor,
    })
}

/// Resolve a cursor's anchor to the index the next page starts at.
fn resume_index(matched_ids: &[&str], cursor: &TaskBoardListCursor) -> Option<usize> {
    let start = cursor.offset.checked_add(1)?;
    (start < matched_ids.len()).then_some(start)
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

/// One case-folded substring needle and its reusable KMP prefix table.
struct FoldedNeedle {
    characters: Vec<char>,
    prefix_lengths: Vec<usize>,
}

impl FoldedNeedle {
    fn new(value: &str) -> Self {
        let characters = value.chars().default_case_fold().collect::<Vec<_>>();
        let mut prefix_lengths = vec![0; characters.len()];
        let mut matched = 0;
        for (index, current) in characters.iter().copied().enumerate().skip(1) {
            while matched > 0 && current != characters[matched] {
                matched = prefix_lengths[matched - 1];
            }
            if current == characters[matched] {
                matched += 1;
            }
            prefix_lengths[index] = matched;
        }
        Self {
            characters,
            prefix_lengths,
        }
    }

    /// Stream the folded haystack so multi-character folds are searchable at
    /// every folded position without allocating a copy of each item field.
    fn is_contained_in(&self, haystack: &str) -> bool {
        if self.characters.is_empty() {
            return true;
        }
        let mut matched = 0;
        for current in haystack.chars().default_case_fold() {
            while matched > 0 && current != self.characters[matched] {
                matched = self.prefix_lengths[matched - 1];
            }
            if current == self.characters[matched] {
                matched += 1;
                if matched == self.characters.len() {
                    return true;
                }
            }
        }
        false
    }
}

/// Reduce one tag to the form a facet compares.
///
/// The write path stores tags exactly as they arrive, so an item really can
/// hold `"backend "`. Case folding also keeps contextual lowercase rules from
/// making two Unicode spellings of the same tag compare differently.
/// Scanning compares every requested tag against every tag on every item, so
/// this walks the characters rather than building a canonical `String` for
/// each of those pairs.
fn canonical_tag_eq(tag: &str, canonical: &str) -> bool {
    tag.trim().chars().default_case_fold().eq(canonical.chars())
}

fn canonical_tag(tag: &str) -> String {
    fold_case(tag.trim())
}

fn fold_case(value: &str) -> String {
    value.chars().default_case_fold().collect()
}

#[cfg(test)]
#[path = "item_query_tests.rs"]
mod tests;
