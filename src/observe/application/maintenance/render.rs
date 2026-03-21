use serde::Serialize;

#[must_use]
pub(in crate::observe::application) fn render_json<T: Serialize>(payload: &T) -> String {
    serde_json::to_string(payload).expect("typed observe JSON serializes")
}

#[must_use]
pub(in crate::observe::application) fn render_pretty_json<T: Serialize>(payload: &T) -> String {
    serde_json::to_string_pretty(payload).expect("typed observe JSON serializes")
}
