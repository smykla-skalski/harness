use super::*;

const KEY: &str = "123e4567-e89b-12d3-a456-426614174000";
const OTHER_KEY: &str = "123e4567-e89b-12d3-a456-426614174001";

#[test]
fn marker_round_trip_preserves_body_bytes() {
    for body in [
        "",
        "Task body",
        " \t",
        "Zażółć gęślą jaźń 🐋",
        "trailing ",
        "trailing\t",
        "trailing\n",
        "trailing\r\n",
        "trailing\n\n\n",
    ] {
        let mut encoded = render_body(body, KEY).expect("render marker");

        assert_eq!(
            encoded,
            format!("{body}\n\n<!-- harness-task-board-create:v1:{KEY} -->")
        );
        assert_eq!(
            extract_from_body(&mut encoded).expect("extract marker"),
            Some(KEY.to_owned())
        );
        assert_eq!(encoded.as_bytes(), body.as_bytes());
    }
}

#[test]
fn renderer_rejects_noncanonical_create_keys() {
    for key in [
        "",
        "123E4567-E89B-12D3-A456-426614174000",
        "123e4567e89b12d3a456426614174000",
        "{123e4567-e89b-12d3-a456-426614174000}",
        "urn:uuid:123e4567-e89b-12d3-a456-426614174000",
        " 123e4567-e89b-12d3-a456-426614174000",
        "123e4567-e89b-12d3-a456-426614174000 ",
        "123e4567-e89b-12d3-a456-42661417400g",
    ] {
        assert!(render_body("body", key).is_err(), "{key}");
    }
}

#[test]
fn embedded_lookalikes_are_ignored_without_mutation() {
    for original in [
        format!("<!-- harness-task-board-create:v1:{KEY} -->\nvisible"),
        format!("<!-- harness-task-board-create:v1:{KEY} -->\nvisible -->"),
        "<!-- harness-task-board-create:v1:not-a-key -->\nvisible".to_owned(),
        "<!-- harness-task-board-created:v1:not-a-key -->".to_owned(),
        "<!-- ordinary comment -->".to_owned(),
    ] {
        let mut body = original.clone();

        assert_eq!(extract_from_body(&mut body).expect("ignore embedded"), None);
        assert_eq!(body, original);
    }
}

#[test]
fn terminal_noncanonical_reserved_forms_fail_without_mutation() {
    let marker = format!("<!-- harness-task-board-create:v1:{KEY} -->");
    for original in [
        marker.clone(),
        format!("body\n{marker}"),
        format!("body\r\n\r\n{marker}"),
        format!("body\n\n{marker}\n"),
        format!("body\n\n{marker} "),
        format!("body\n\n{marker}\u{a0}"),
        format!("body\n\n<!-- harness-task-board-create:v2:{KEY} -->"),
        format!("body\n\n<!-- HARNESS-TASK-BOARD-CREATE:v1:{KEY} -->"),
        format!("body\n\n<!-- harness-task-board-create:V1:{KEY} -->"),
        format!("body\n\n<!-- harness-task-board-create:v1: {KEY} -->"),
        format!("body\n\n<!-- harness-task-board-create:v1:{KEY}-->"),
        format!("body\n\n<!-- harness-task-board-create:v1:{KEY} -- >"),
        format!("body\n\n<!-- harness-task-board-create:v1:{KEY} <!-- -->"),
        "body\n\n<!-- harness-task-board-create:v1:not-a-key -->".to_owned(),
    ] {
        let mut body = original.clone();

        assert!(extract_from_body(&mut body).is_err(), "{original:?}");
        assert_eq!(body, original);
    }
}

#[test]
fn duplicate_terminal_reserved_forms_fail_without_mutation() {
    for original in [
        format!(
            "body\n\n<!-- harness-task-board-create:v1:{KEY} -->\n\n\
             <!-- harness-task-board-create:v1:{KEY} -->"
        ),
        format!(
            "body\n\n<!-- harness-task-board-create:v1:{KEY} -->\n\n\
             <!-- harness-task-board-create:v1:{OTHER_KEY} -->"
        ),
        format!(
            "body\n\n<!-- harness-task-board-create:v1:not-a-key -->\n\n\
             <!-- harness-task-board-create:v1:{KEY} -->"
        ),
    ] {
        let mut body = original.clone();

        assert!(extract_from_body(&mut body).is_err());
        assert_eq!(body, original);
    }
}

#[test]
fn renderer_rejects_terminal_reserved_evidence() {
    let canonical = format!("body\n\n<!-- harness-task-board-create:v1:{KEY} -->");
    let malformed = "body\n\n<!-- harness-task-board-create:v1:not-a-key -->";
    let ambiguous = format!("body\n\n<!-- harness-task-board-create:v1:{KEY} <!-- -->");

    assert!(render_body(&canonical, KEY).is_err());
    assert!(render_body(&format!("{canonical}\nvisible"), KEY).is_ok());
    assert!(render_body(malformed, KEY).is_err());
    assert!(render_body(&format!("{malformed}\nvisible"), KEY).is_ok());
    assert!(render_body(&ambiguous, KEY).is_err());
}

#[test]
fn embedded_lookalikes_are_preserved_when_terminal_marker_is_removed() {
    for original in [
        format!("body\n<!-- harness-task-board-create:v1:{OTHER_KEY} -->\nvisible"),
        format!("body\n<!-- harness-task-board-create:v1:{OTHER_KEY} -->\nvisible -->"),
        "body\n<!-- harness-task-board-create:v1:not-a-key -->\nvisible".to_owned(),
    ] {
        let mut marked = render_body(&original, KEY).expect("render terminal marker");

        assert_eq!(
            extract_from_body(&mut marked).expect("extract terminal marker"),
            Some(KEY.to_owned())
        );
        assert_eq!(marked, original);
    }
}
