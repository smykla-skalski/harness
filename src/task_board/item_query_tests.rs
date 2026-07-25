use super::{
    TASK_BOARD_LIST_DEFAULT_LIMIT, TASK_BOARD_LIST_MAX_CURSOR_CHARS, TASK_BOARD_LIST_MAX_LIMIT,
    TaskBoardItemQuery, TaskBoardListCursor, TaskBoardQueryTarget, normalize_query_text,
    select_page, validated_limit,
};
use crate::task_board::types::{AgentMode, TaskBoardItem, TaskBoardPriority, TaskBoardStatus};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;

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
fn tag_facets_use_unicode_case_folding() {
    let mut item = item("task-1", "Ship the thing", "body");
    item.tags = vec!["ΟΣ".to_string()];

    for tag in ["ΟΣ", "οσ", "ος"] {
        let query = TaskBoardItemQuery {
            tags: vec![tag.to_string()],
            ..TaskBoardItemQuery::default()
        };
        assert!(
            query.prepared().matches(&item.query_fields()),
            "expected {tag} to match"
        );
    }
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

/// Matching walks characters instead of lowercasing each haystack, so the
/// cases that scan has to keep getting right are worth pinning: a match at the
/// very end, a needle longer than what remains, and a non-ASCII fold.
#[test]
fn text_matching_walks_the_haystack_without_lowercasing_it() {
    let mut item = item("task-1", "Ship the Widget", "the CAUSE was a race");
    item.tags = vec!["Zoë".to_string()];

    for (text, expected) in [
        ("race", true),
        ("a race and more", false),
        ("zoë", true),
        ("SHIP", true),
        ("widgets", false),
    ] {
        let query = TaskBoardItemQuery {
            text: Some(text.to_lowercase()),
            ..TaskBoardItemQuery::default()
        };
        assert_eq!(
            query.prepared().matches(&item.query_fields()),
            expected,
            "{text}"
        );
    }
}

#[test]
fn text_search_uses_unicode_case_folding_for_every_searchable_field() {
    let mut tag_item = item("tag", "plain", "plain");
    tag_item.tags = vec!["ΟΣ".to_string()];
    for (item, text) in [
        (item("title", "ΟΣ", "plain"), "ΟΣ"),
        (item("body", "plain", "Straße"), "STRASSE"),
        (item("fold-expansion", "plain", "Straße"), "SE"),
        (tag_item, "ος"),
    ] {
        let query = TaskBoardItemQuery {
            text: Some(text.to_string()),
            ..TaskBoardItemQuery::default()
        };
        assert!(
            query.prepared().matches(&item.query_fields()),
            "expected {text} to match"
        );
    }
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
        let page = select_page(&ids, cursor.as_ref(), 3, 7).expect("stable page");
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
    let cursor = TaskBoardListCursor::for_page(17, 41);
    assert_eq!(TaskBoardListCursor::decode(&cursor.encode()), Some(cursor));
}

#[test]
fn a_malformed_cursor_decodes_to_nothing() {
    let oversized = "x".repeat(TASK_BOARD_LIST_MAX_CURSOR_CHARS + 1);

    for raw in ["", "not-base64!!", "MTI", "eDp0YXNrLTE", oversized.as_str()] {
        assert_eq!(TaskBoardListCursor::decode(raw), None, "accepted {raw}");
    }
}

#[test]
fn every_emitted_cursor_is_bounded_and_resumable_after_a_long_id() {
    let long_id = "x".repeat(TASK_BOARD_LIST_MAX_CURSOR_CHARS * 2);
    let ids = [long_id.as_str(), "task-next"];
    let first = select_page(&ids, None, 1, 9).expect("first page");
    let cursor = first.next_cursor.expect("second page");
    let encoded = cursor.encode();

    assert!(encoded.len() <= TASK_BOARD_LIST_MAX_CURSOR_CHARS);
    let decoded = TaskBoardListCursor::decode(&encoded).expect("issued cursor decodes");
    let second = select_page(&ids, Some(&decoded), 1, 9).expect("second page");
    assert_eq!(&ids[second.start..second.end], ["task-next"]);
}

#[test]
fn a_cursor_refuses_a_changed_board_sequence() {
    let original = ["task-a", "task-b", "task-c", "task-d", "task-e"];
    let first = select_page(&original, None, 2, 41).expect("first page");
    let cursor = first.next_cursor.expect("more pages");
    let reordered = ["task-a", "task-c", "task-d", "task-b", "task-e"];

    assert_eq!(select_page(&reordered, Some(&cursor), 2, 42), None);
}

#[test]
fn a_legacy_cursor_is_refused_instead_of_resuming_without_a_snapshot() {
    let legacy = URL_SAFE_NO_PAD.encode("1:task-1");

    assert_eq!(TaskBoardListCursor::decode(&legacy), None);
}

#[test]
fn the_last_page_reports_no_further_cursor() {
    let ids = ["task-0", "task-1"];
    let page = select_page(&ids, None, 2, 1).expect("last page");
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
