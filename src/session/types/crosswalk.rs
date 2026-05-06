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
        RuntimeSessionId, effective_runtime_session_key, matches_runtime_session_id,
        normalized_runtime_session_id,
    };

    #[test]
    fn runtime_session_helpers_trim_and_match_explicit_runtime_identity() {
        assert_eq!(
            normalized_runtime_session_id(Some("  runtime-1  ")),
            Some(RuntimeSessionId::from("runtime-1"))
        );
        assert_eq!(
            effective_runtime_session_key(
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
                Some(" runtime-1 ")
            ),
            "runtime-1"
        );
        assert!(matches_runtime_session_id(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            Some("runtime-1"),
            &RuntimeSessionId::from("runtime-1")
        ));
        assert!(!matches_runtime_session_id(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            Some("runtime-1"),
            &RuntimeSessionId::from("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        ));
    }
}
