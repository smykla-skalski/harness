use super::*;

#[test]
fn production_support_includes_core_run_blocks() {
    let deps = RunDependencies::production();
    for requirement in ["docker", "kubernetes", "build"] {
        assert!(
            deps.validate_requirement_names(&[requirement.to_string()])
                .is_ok(),
            "missing supported requirement: {requirement}"
        );
    }
    assert!(
        deps.validate_requirement_names(&["envoy".to_string()])
            .is_err()
    );
}

#[test]
fn validate_requirement_names_rejects_unknown_names() {
    let support = RequirementSupport::with_supported([BlockRequirement::Docker]);
    let error = support
        .validate_names(&["not-a-block".to_string()])
        .expect_err("expected unknown requirement to fail");
    assert_eq!(
        error.details(),
        Some("unknown block requirement: not-a-block")
    );
}

#[test]
fn validate_requirement_names_reports_missing_block() {
    let support = RequirementSupport::with_supported([BlockRequirement::Docker]);
    let error = support
        .validate_names(&["kubernetes".to_string()])
        .expect_err("expected unsupported requirement to fail");
    assert_eq!(error.details(), Some("missing required blocks: kubernetes"));
}
