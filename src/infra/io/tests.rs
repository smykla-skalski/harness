use super::*;
use serde_json::json;
use tempfile::TempDir;

#[test]
fn write_and_read_json() {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("test.json");
    let payload = json!({"key": "value", "num": 42});
    write_json(&path, &payload).unwrap();
    let data = read_json(&path).unwrap();
    assert_eq!(data["key"], "value");
    assert_eq!(data["num"], 42);
}

#[test]
fn read_json_rejects_corrupt_json() {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("bad.json");
    fs::write(&path, "not json {").unwrap();
    let err = read_json(&path).unwrap_err();
    assert_eq!(err.code(), "KSRCLI019");
}

#[test]
fn read_text_missing_file() {
    let tmp = TempDir::new().unwrap();
    let err = read_text(&tmp.path().join("nope.txt")).unwrap_err();
    assert!(err.message().contains("missing file"));
}

#[test]
fn write_text_creates_parents() {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("a").join("b").join("c.txt");
    write_text(&path, "hello").unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), "hello");
}

#[test]
fn ensure_mapping_rejects_non_dict() {
    let val = json!("string");
    assert!(ensure_mapping(&val, "test").is_err());
}

#[test]
fn ensure_str_list_rejects_non_strings() {
    let val = json!([1, 2, 3]);
    assert!(ensure_str_list(&val, "test").is_err());
}

#[derive(Debug, serde::Deserialize, PartialEq, Eq)]
struct FrontmatterFixture {
    name: String,
    count: i64,
}

#[test]
fn parse_frontmatter_valid() {
    let text = "---\nname: test\ncount: 3\n---\n\nBody content here.";
    let parsed = parse_frontmatter::<FrontmatterFixture>(text, "fixture").unwrap();
    assert_eq!(
        parsed.frontmatter,
        FrontmatterFixture {
            name: "test".to_string(),
            count: 3,
        }
    );
    assert_eq!(parsed.body, "Body content here.");
}

#[test]
fn parse_frontmatter_missing() {
    let err = parse_frontmatter::<FrontmatterFixture>("no frontmatter", "fixture").unwrap_err();
    assert!(err.message().contains("missing YAML frontmatter"));
}

#[test]
fn parse_frontmatter_unterminated() {
    let err = parse_frontmatter::<FrontmatterFixture>("---\nname: test\n", "fixture").unwrap_err();
    assert!(err.message().contains("unterminated"));
}

#[test]
fn as_mapping_returns_none_for_non_dict() {
    assert!(as_mapping(&json!("string")).is_none());
    assert!(as_mapping(&json!(42)).is_none());
}

#[test]
fn as_mapping_returns_map() {
    let val = json!({"key": "value"});
    let map = as_mapping(&val).unwrap();
    assert_eq!(map.get("key").unwrap(), &json!("value"));
}

#[test]
fn as_list_returns_empty_for_non_list() {
    assert!(as_list(&json!("string")).is_empty());
}

#[test]
fn drill_navigates_nested_dicts() {
    let data = json!({"a": {"b": {"c": "found"}}});
    assert_eq!(drill(&data, "a.b.c").unwrap(), &json!("found"));
}

#[test]
fn drill_raises_on_missing_path() {
    let data = json!({"a": 1});
    let err = drill(&data, "a.b.c").unwrap_err();
    assert!(err.message().contains("path not found"));
}

#[test]
fn is_safe_name_accepts_normal_names() {
    assert!(is_safe_name("my-suite"));
    assert!(is_safe_name("g01.md"));
}

#[test]
fn is_safe_name_rejects_unsafe() {
    assert!(!is_safe_name(""));
    assert!(!is_safe_name("a/b"));
    assert!(!is_safe_name("a\\b"));
    assert!(!is_safe_name("a..b"));
}

#[test]
fn validate_safe_segment_accepts_valid() {
    assert!(validate_safe_segment("my-run").is_ok());
    assert!(validate_safe_segment("g01.md").is_ok());
}

#[test]
fn validate_safe_segment_rejects_traversal() {
    let err = validate_safe_segment("../../etc/passwd").unwrap_err();
    assert_eq!(err.code(), "KSRCLI059");
}

#[test]
fn validate_safe_segment_rejects_empty() {
    assert!(validate_safe_segment("").is_err());
}

#[test]
fn append_markdown_row_rejects_shape_mismatch() {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("log.md");
    let err = append_markdown_row(&path, &["a", "b"], &["1"]).unwrap_err();
    assert!(
        err.message().contains("shape mismatch"),
        "expected shape mismatch error, got: {}",
        err.message()
    );
}

#[test]
fn append_markdown_row_creates_table() {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("log.md");
    append_markdown_row(&path, &["a", "b"], &["1", "2"]).unwrap();
    let content = fs::read_to_string(&path).unwrap();
    assert!(content.contains("| a | b |"));
    assert!(content.contains("| 1 | 2 |"));
}

#[test]
fn append_markdown_row_appends_to_existing() {
    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("log.md");
    append_markdown_row(&path, &["a"], &["1"]).unwrap();
    append_markdown_row(&path, &["a"], &["2"]).unwrap();
    let content = fs::read_to_string(&path).unwrap();
    assert_eq!(content.matches("| 1 |").count(), 1);
    assert_eq!(content.matches("| 2 |").count(), 1);
}

#[cfg(unix)]
#[test]
fn write_text_sets_owner_only_permissions() {
    use std::os::unix::fs::PermissionsExt;

    let tmp = TempDir::new().unwrap();
    let path = tmp.path().join("secret.txt");
    write_text(&path, "sensitive data").unwrap();
    let metadata = fs::metadata(&path).unwrap();
    let mode = metadata.permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "expected 0600, got {mode:o}");
}
