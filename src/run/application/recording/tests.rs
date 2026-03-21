use super::*;

#[test]
fn validate_gid_usage_requires_gid_for_execution_phase() {
    let error = validate_gid_usage("execution", None, true).unwrap_err();
    assert!(error.message().contains("--gid is required"));
}

#[test]
fn validate_gid_usage_rejects_gid_outside_execution_phase() {
    let error = validate_gid_usage("bootstrap", Some("g01"), true).unwrap_err();
    assert!(error.message().contains("only allowed"));
}

#[test]
fn validate_gid_usage_allows_execution_with_gid() {
    validate_gid_usage("execution", Some("g01"), true).unwrap();
}

#[test]
fn log_group_id_uses_dash_outside_execution_phase() {
    assert_eq!(log_group_id("closeout", Some("g01")), "-");
}
