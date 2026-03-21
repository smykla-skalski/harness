use super::BlockRequirement;

#[test]
fn denied_binaries_cover_managed_cluster_tools() {
    for name in [
        "docker",
        "kubectl",
        "kubectl-validate",
        "k3d",
        "helm",
        "kumactl",
    ] {
        assert!(
            BlockRequirement::ALL
                .iter()
                .flat_map(|requirement| requirement.denied_binaries().iter().copied())
                .any(|binary| binary == name),
            "missing denied binary: {name}"
        );
    }
}

#[test]
fn parse_rejects_unknown_requirement() {
    let error = BlockRequirement::parse("not-a-block").unwrap_err();
    assert_eq!(
        error.cause.to_string(),
        "unknown block requirement: not-a-block"
    );
}
