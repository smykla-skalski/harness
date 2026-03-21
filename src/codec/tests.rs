use serde::{Deserialize, Serialize};
use serde_json::json;

use super::*;

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct Simple {
    name: String,
    enabled: bool,
    count: i64,
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct WithDefaults {
    name: String,
    #[serde(default = "default_color")]
    color: String,
    #[serde(default = "default_limit")]
    limit: i64,
}

fn default_color() -> String {
    "blue".to_string()
}

const fn default_limit() -> i64 {
    10
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct WithRemap {
    #[serde(rename = "display_name")]
    name: String,
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct WithNonSource {
    name: String,
    injected_path: String,
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct WithEmitFalse {
    name: String,
    #[serde(skip_serializing)]
    internal: String,
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct WithAllowEmpty {
    tag: String,
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct WithTuple {
    items: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct WithDict {
    config: Map<String, Value>,
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct Inner {
    value: String,
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct Outer {
    name: String,
    child: Inner,
}

#[test]
fn test_from_mapping_basic() {
    let input = json!({"name": "foo", "enabled": true, "count": 3});
    let result: Simple = from_mapping(&input, "simple").unwrap();
    assert_eq!(result.name, "foo");
    assert!(result.enabled);
    assert_eq!(result.count, 3);
}

#[test]
fn test_from_mapping_missing_fields() {
    let input = json!({"name": "foo"});
    let err = from_mapping::<Simple>(&input, "simple").unwrap_err();
    let msg = err.to_string();
    assert!(msg.contains("missing required fields"), "got: {msg}");
    assert!(msg.contains("enabled"), "got: {msg}");
    assert!(msg.contains("count"), "got: {msg}");
}

#[test]
fn test_from_mapping_type_mismatch_str() {
    let input = json!({"name": 42, "enabled": true, "count": 1});
    let err = from_mapping::<Simple>(&input, "simple").unwrap_err();
    let msg = err.to_string();
    assert!(msg.contains("field type mismatch"), "got: {msg}");
    assert!(msg.contains("expected string"), "got: {msg}");
}

#[test]
fn test_from_mapping_type_mismatch_bool() {
    let input = json!({"name": "x", "enabled": "yes", "count": 1});
    let err = from_mapping::<Simple>(&input, "simple").unwrap_err();
    let msg = err.to_string();
    assert!(msg.contains("field type mismatch"), "got: {msg}");
    assert!(msg.contains("expected boolean"), "got: {msg}");
}

#[test]
fn test_from_mapping_allow_empty() {
    let input = json!({"tag": ""});
    let result: WithAllowEmpty = from_mapping(&input, "allowempty").unwrap();
    assert_eq!(result.tag, "");
}

#[test]
fn test_from_mapping_key_remap() {
    let input = json!({"display_name": "hello"});
    let result: WithRemap = from_mapping(&input, "remap").unwrap();
    assert_eq!(result.name, "hello");
}

#[test]
fn test_from_mapping_source_false() {
    let input = json!({"name": "a"});
    let mut injected = Map::new();
    injected.insert("injected_path".to_string(), json!("/tmp/x"));
    let result: WithNonSource = from_mapping_with_injected(&input, &injected, "nonsource").unwrap();
    assert_eq!(result.name, "a");
    assert_eq!(result.injected_path, "/tmp/x");
}

#[test]
fn test_from_mapping_emit_false() {
    let input = json!({"name": "a"});
    let mut injected = Map::new();
    injected.insert("internal".to_string(), json!("secret"));
    let obj: WithEmitFalse = from_mapping_with_injected(&input, &injected, "emitfalse").unwrap();
    let mapping = to_mapping(&obj);
    assert!(mapping.contains_key("name"));
    assert!(!mapping.contains_key("internal"));
}

#[test]
fn test_from_mapping_tuple_of_str() {
    let input = json!({"items": ["a", "b", "c"]});
    let result: WithTuple = from_mapping(&input, "withtuple").unwrap();
    assert_eq!(result.items, vec!["a", "b", "c"]);
}

#[test]
fn test_from_mapping_dict_field() {
    let input = json!({"config": {"key": "val"}});
    let result: WithDict = from_mapping(&input, "withdict").unwrap();
    let mut expected = Map::new();
    expected.insert("key".to_string(), json!("val"));
    assert_eq!(result.config, expected);
}

#[test]
fn test_from_mapping_nested_struct() {
    let input = json!({"name": "top", "child": {"value": "nested"}});
    let result: Outer = from_mapping(&input, "outer").unwrap();
    assert_eq!(result.name, "top");
    assert_eq!(result.child.value, "nested");
}

#[test]
fn test_to_mapping_round_trip() {
    let original = json!({"name": "foo", "enabled": true, "count": 3});
    let obj: Simple = from_mapping(&original, "simple").unwrap();
    let mapping = to_mapping(&obj);
    assert_eq!(Value::Object(mapping), original);
}

#[test]
fn test_from_mapping_with_defaults() {
    let input = json!({"name": "test"});
    let result: WithDefaults = from_mapping(&input, "with-defaults").unwrap();
    assert_eq!(result.name, "test");
    assert_eq!(result.color, "blue");
    assert_eq!(result.limit, 10);
}
