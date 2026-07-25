use super::{
    TASK_BOARD_LIST_DEFAULT_LIMIT, TASK_BOARD_LIST_MAX_LIMIT, TaskBoardItemQuery,
    TaskBoardListCursor, TaskBoardQueryTarget, normalize_query_text, select_page, validated_limit,
};
use crate::task_board::types::{AgentMode, TaskBoardItem, TaskBoardPriority, TaskBoardStatus};

fn item(id: &str, title: &str, body: &str) -> TaskBoardItem {
    TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        body.to_string(),
        "2026-07-25T00:00:00Z".to_string(),
    )
}

fn ids<'a>(items: &'a [TaskBoardItem]) -> Vec<&'a str> {
    items.iter().map(|item| item.id.as_str()).collect()
}

#[test]
fn an_empty_query_matches_every_item() {
    let item = item("task-1", "Ship the thing", "with a body");
    assert!(TaskBoardItemQuery::default().prepared().matches(&item.query_fields()));
}

#[test]
fn facets_narrow_by_field_value() {
    let mut item = item("task-1", "Ship the thing", "body");
    item.priority = TaskBoardPriority::High;
    item.agent_mode = AgentMode::Planning;
    item.project_id = Some("project-alpha".to_string());

    let matching = TaskBoardItemQuery {
        priority: Some(TaskBoardPriority::High),
        agent_mode: Some(AgentMode::Planning),
        project_id: Some("project-alpha".to_string()),
        ..TaskBoardItemQuery::default()
    };
    assert!(matching.prepared().matches(&item.query_fields()));

    let wrong_project = TaskBoardItemQuery {
        project_id: Some("project-beta".to_string()),
        ..TaskBoardItemQuery::default()
    };
    assert!(!wrong_project.prepared().matches(&item.query_fields()));

    let wrong_priority = TaskBoardItemQuery {
        priority: Some(TaskBoardPriority::Low),
        ..TaskBoardItemQuery::default()
    };
    assert!(!wrong_priority.prepared().matches(&item.query_fields()));
}

/// A status facet has to read the same lane a persisted item does, or every
/// alias (`new`, `plan_review`, `needs_you`, `blocked`) would silently match
/// nothing.
#[test]
fn a_status_facet_matches_through_its_canonical_alias() {
    let mut item = item("task-1", "Ship the thing", "body");
    item.status = TaskBoardStatus::Todo;
    let query = TaskBoardItemQuery {
        status: Some(TaskBoardStatus::New),
        ..TaskBoardItemQuery::default()
    };
    assert!(query.prepared().matches(&item.query_fields()));
}

#[test]
fn every_requested_tag_must_be_present() {
    let mut item = item("task-1", "Ship the thing", "body");
    item.tags = vec!["backend".to_string(), "Urgent".to_string()];

    let both = TaskBoardItemQuery {
        tags: vec!["backend".to_string(), "urgent".to_string()],
        ..TaskBoardItemQuery::default()
    };
    assert!(both.prepared().matches(&item.query_fields()));

    let missing_one = TaskBoardItemQuery {
        tags: vec!["backend".to_string(), "frontend".to_string()],
        ..TaskBoardItemQuery::default()
    };
    assert!(!missing_one.prepared().matches(&item.query_fields()));
}

/// Tags are stored exactly as they arrive, so both sides have to be reduced
/// the same way or a tag written with a stray space is unmatchable.
#[test]
fn a_tag_facet_ignores_surrounding_whitespace_on_either_side() {
    let mut item = item("task-1", "Ship the thing", "body");
    item.tags = vec!["Backend ".to_string()];

    let query = TaskBoardItemQuery {
        tags: vec![" backend".to_string()],
        ..TaskBoardItemQuery::default()
    };
    assert!(query.prepared().matches(&item.query_fields()));
}

#[test]
fn text_matches_title_body_and_tags_case_insensitively() {
    let mut item = item("task-1", "Ship the Widget", "the CAUSE was a race");
    item.tags = vec!["release-train".to_string()];

    for text in ["widget", "cause", "RELEASE-train"] {
        let query = TaskBoardItemQuery {
            text: Some(text.to_string()),
            ..TaskBoardItemQuery::default()
        };
        assert!(
            query.prepared().matches(&item.query_fields()),
            "expected {text} to match"
        );
    }

    let miss = TaskBoardItemQuery {
        text: Some("absent".to_string()),
        ..TaskBoardItemQuery::default()
    };
    assert!(!miss.prepared().matches(&item.query_fields()));
}

#[test]
fn paging_a_stable_selection_never_repeats_or_skips_an_item() {
    let items = (0..7)
        .map(|index| item(&format!("task-{index}"), "title", "body"))
        .collect::<Vec<_>>();
    let ids = ids(&items);

    let mut seen = Vec::new();
    let mut cursor = None;
    loop {
        let page = select_page(&ids, cursor.as_ref(), 3);
        seen.extend_from_slice(&ids[page.start..page.end]);
        match page.next_cursor {
            Some(next) => cursor = Some(next),
            None => break,
        }
    }

    assert_eq!(seen, ids);
}

#[test]
fn a_cursor_survives_an_encode_and_decode_round_trip() {
    let cursor = TaskBoardListCursor {
        offset: 41,
        item_id: "task-with:colon".to_string(),
    };
    assert_eq!(TaskBoardListCursor::decode(&cursor.encode()), Some(cursor));
}

/// `MTI` is base64url for `12`: well-formed base64 carrying no
/// `offset:item_id` separator.
#[test]
fn a_malformed_cursor_decodes_to_nothing() {
    for raw in ["", "not-base64!!", "MTI", "eDp0YXNrLTE"] {
        assert_eq!(TaskBoardListCursor::decode(raw), None, "accepted {raw}");
    }
}

/// A page whose anchor was deleted between reads resumes at the slot that
/// anchor held, so the reader still advances instead of replaying the page.
#[test]
fn a_cursor_whose_anchor_left_the_selection_resumes_at_its_slot() {
    let items = (0..5)
        .map(|index| item(&format!("task-{index}"), "title", "body"))
        .collect::<Vec<_>>();
    let ids = ids(&items);
    let first = select_page(&ids, None, 2);
    let cursor = first.next_cursor.expect("more pages");

    let remaining = ["task-0", "task-2", "task-3", "task-4"];
    let page = select_page(&remaining, Some(&cursor), 2);

    assert_eq!(&remaining[page.start..page.end], ["task-2", "task-3"]);
}

#[test]
fn the_last_page_reports_no_further_cursor() {
    let ids = ["task-0", "task-1"];
    let page = select_page(&ids, None, 2);
    assert_eq!(page.next_cursor, None);
    assert_eq!(page.end, 2);
}

#[test]
fn an_absent_limit_falls_back_to_the_default_and_an_out_of_range_one_is_refused() {
    assert_eq!(validated_limit(None), Some(TASK_BOARD_LIST_DEFAULT_LIMIT));
    assert_eq!(validated_limit(Some(1)), Some(1));
    assert_eq!(
        validated_limit(Some(TASK_BOARD_LIST_MAX_LIMIT)),
        Some(TASK_BOARD_LIST_MAX_LIMIT)
    );
    assert_eq!(validated_limit(Some(0)), None);
    assert_eq!(validated_limit(Some(TASK_BOARD_LIST_MAX_LIMIT + 1)), None);
}

#[test]
fn blank_query_text_selects_nothing_extra() {
    assert_eq!(normalize_query_text(None), None);
    assert_eq!(normalize_query_text(Some("   ")), None);
    assert_eq!(
        normalize_query_text(Some("  widget ")),
        Some("widget".to_string())
    );
}
