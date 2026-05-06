use super::RuntimeSessionId;

#[must_use]
pub(crate) fn normalized_runtime_session_id(
    runtime_session_id: Option<&str>,
) -> Option<RuntimeSessionId> {
    runtime_session_id
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(RuntimeSessionId::from)
}

#[must_use]
pub(crate) fn effective_runtime_session_key<'a>(
    orchestration_session_id: &'a str,
    runtime_session_id: Option<&'a str>,
) -> &'a str {
    runtime_session_id
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(orchestration_session_id)
}

#[must_use]
pub(crate) fn legacy_compatible_signal_session_keys(
    orchestration_session_id: &str,
    runtime_session_id: Option<&str>,
) -> Vec<String> {
    // Read both the canonical runtime-session key and the legacy
    // orchestration-session key while older signal directories remain
    // supported. New writes must keep using `effective_runtime_session_key`;
    // delete this helper once pre-canonical signal layouts are out of support.
    let mut keys = Vec::new();
    if let Some(runtime_session_id) = normalized_runtime_session_id(runtime_session_id) {
        keys.push(runtime_session_id.into_inner());
    }
    if keys
        .last()
        .is_none_or(|last| last.as_str() != orchestration_session_id)
    {
        keys.push(orchestration_session_id.to_string());
    }
    keys
}

#[must_use]
pub(crate) fn matches_runtime_session_id(
    orchestration_session_id: &str,
    runtime_session_id: Option<&str>,
    candidate: &RuntimeSessionId,
) -> bool {
    effective_runtime_session_key(orchestration_session_id, runtime_session_id)
        == candidate.as_str()
}

#[cfg(test)]
mod tests {
    use super::{
        RuntimeSessionId, effective_runtime_session_key, legacy_compatible_signal_session_keys,
        matches_runtime_session_id, normalized_runtime_session_id,
    };

    #[test]
    fn legacy_compatible_signal_session_keys_keep_runtime_key_then_legacy_session_key() {
        assert_eq!(
            legacy_compatible_signal_session_keys("sess-1", Some("runtime-1")),
            vec!["runtime-1".to_string(), "sess-1".to_string()]
        );
    }

    #[test]
    fn legacy_compatible_signal_session_keys_deduplicate_matching_keys() {
        assert_eq!(
            legacy_compatible_signal_session_keys("sess-1", Some("sess-1")),
            vec!["sess-1".to_string()]
        );
    }

    #[test]
    fn runtime_session_helpers_trim_and_match_explicit_runtime_identity() {
        assert_eq!(
            normalized_runtime_session_id(Some("  runtime-1  ")),
            Some(RuntimeSessionId::from("runtime-1"))
        );
        assert_eq!(
            effective_runtime_session_key("sess-1", Some(" runtime-1 ")),
            "runtime-1"
        );
        assert!(matches_runtime_session_id(
            "sess-1",
            Some("runtime-1"),
            &RuntimeSessionId::from("runtime-1")
        ));
        assert!(!matches_runtime_session_id(
            "sess-1",
            Some("runtime-1"),
            &RuntimeSessionId::from("sess-1")
        ));
    }
}
