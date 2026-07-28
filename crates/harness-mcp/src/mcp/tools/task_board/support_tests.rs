use serde_json::{Value, json};

use super::validate_params;

#[test]
fn null_arguments_normalize_to_an_empty_object() {
    let schema = json!({
        "type": "object",
        "additionalProperties": false
    });

    assert_eq!(
        validate_params(Value::Null, &schema).expect("normalize null"),
        json!({})
    );
}

#[test]
fn required_type_and_enum_constraints_are_enforced() {
    let schema = json!({
        "type": "object",
        "properties": {
            "status": {
                "type": "string",
                "enum": ["todo", "done"]
            }
        },
        "required": ["status"],
        "additionalProperties": false
    });

    assert!(validate_params(json!({}), &schema).is_err());
    assert!(validate_params(json!({ "status": 2 }), &schema).is_err());
    assert!(validate_params(json!({ "status": "blocked" }), &schema).is_err());
    assert!(validate_params(json!({ "status": "todo" }), &schema).is_ok());
}

#[test]
fn empty_object_schema_rejects_unknown_fields() {
    let schema = json!({
        "type": "object",
        "properties": {},
        "additionalProperties": false
    });

    assert!(validate_params(json!({ "unexpected": true }), &schema).is_err());
}

#[test]
fn any_of_accepts_each_variant_and_rejects_the_rest() {
    let schema = json!({
        "type": "object",
        "properties": {
            "cursor": {
                "anyOf": [
                    { "type": "integer", "minimum": 1 },
                    { "type": "string" }
                ]
            }
        },
        "additionalProperties": false
    });

    assert!(validate_params(json!({ "cursor": 12 }), &schema).is_ok());
    assert!(validate_params(json!({ "cursor": "18446744073709551615" }), &schema).is_ok());
    assert!(validate_params(json!({ "cursor": 0 }), &schema).is_err());
    assert!(validate_params(json!({ "cursor": true }), &schema).is_err());
}

#[test]
fn array_items_are_validated_recursively() {
    let schema = json!({
        "type": "object",
        "properties": {
            "tags": {
                "type": "array",
                "items": { "type": "string" }
            }
        },
        "additionalProperties": false
    });

    assert!(validate_params(json!({ "tags": ["mcp", "cli"] }), &schema).is_ok());
    assert!(validate_params(json!({ "tags": ["mcp", 1] }), &schema).is_err());
}

#[test]
fn maximum_and_disallowed_field_combinations_are_enforced() {
    let schema = json!({
        "type": "object",
        "properties": {
            "value": {
                "type": "integer",
                "minimum": 1,
                "maximum": 9_223_372_036_854_775_807_u64
            },
            "clear": { "type": "boolean" }
        },
        "allOf": [{
            "not": {
                "properties": { "clear": { "const": true } },
                "required": ["value", "clear"]
            }
        }],
        "additionalProperties": false
    });

    assert!(validate_params(json!({ "value": 1 }), &schema).is_ok());
    assert!(validate_params(json!({ "value": 9_223_372_036_854_775_807_u64 }), &schema).is_ok());
    assert!(validate_params(json!({ "value": 9_223_372_036_854_775_808_u64 }), &schema).is_err());
    assert!(validate_params(json!({ "value": 1, "clear": false }), &schema).is_ok());
    assert!(validate_params(json!({ "value": 1, "clear": true }), &schema).is_err());
}

#[test]
fn valid_payload_is_forwarded_without_rewriting() {
    let schema = json!({
        "type": "object",
        "properties": {
            "title": { "type": "string" },
            "tags": {
                "type": "array",
                "items": { "type": "string" }
            }
        },
        "required": ["title"],
        "additionalProperties": false
    });
    let payload = json!({
        "title": "Split the MCP worker",
        "tags": ["mcp", "isolation"]
    });

    assert_eq!(
        validate_params(payload.clone(), &schema).expect("validate payload"),
        payload
    );
}
