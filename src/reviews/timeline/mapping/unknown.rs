#![allow(dead_code)]

use serde_json::Value;

use super::super::types::{ReviewTimelineEntry, UnknownEntry};
use super::helpers::{parse_actor, parse_iso8601};

/// Forward-compat fallback for GraphQL timeline nodes whose
/// `__typename` is not in the hot-kind dispatch nor the
/// `SimpleActorEvent` table. Preserves the raw JSON in
/// `UnknownEntry.raw_payload` so the Swift side can render whatever
/// it can extract while still surfacing a row in the timeline.
pub(super) fn map_unknown(typename: &str, node: &Value) -> Option<ReviewTimelineEntry> {
    let id = node
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| format!("unknown:{typename}"));
    let created_at = parse_iso8601(node.get("createdAt"))?;
    let actor = parse_actor(node.get("actor"));
    Some(ReviewTimelineEntry::Unknown(UnknownEntry {
        id,
        created_at,
        actor,
        typename: typename.to_string(),
        raw_payload: node.clone(),
    }))
}
