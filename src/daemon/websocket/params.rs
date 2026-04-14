use serde_json::Value;

use crate::daemon::protocol::TimelineCursor;

pub(crate) fn extract_session_id(params: &Value) -> Option<String> {
    extract_string_param(params, "session_id")
}

pub(crate) fn extract_string_param(params: &Value, key: &str) -> Option<String> {
    params.get(key).and_then(Value::as_str).map(String::from)
}

pub(crate) fn extract_u64_param(params: &Value, key: &str) -> Option<u64> {
    params.get(key).and_then(Value::as_u64)
}

pub(crate) fn extract_i64_param(params: &Value, key: &str) -> Option<i64> {
    params.get(key).and_then(Value::as_i64)
}

pub(crate) fn extract_cursor_param(params: &Value, key: &str) -> Option<TimelineCursor> {
    let object = params.as_object()?;
    let cursor = object.get(key)?.as_object()?;
    Some(TimelineCursor {
        recorded_at: cursor.get("recorded_at")?.as_str()?.to_string(),
        entry_id: cursor.get("entry_id")?.as_str()?.to_string(),
    })
}
