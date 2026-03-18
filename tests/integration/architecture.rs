use std::path::Path;

#[test]
fn new_domain_roots_exist() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for path in [
        "ARCHITECTURE.md",
        "src/app",
        "src/run",
        "src/authoring",
        "src/observe",
        "src/setup",
        "src/platform",
        "src/infra",
        "src/hooks",
    ] {
        assert!(root.join(path).exists(), "missing expected path: {path}");
    }
}

#[test]
fn legacy_scatter_roots_are_gone() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for path in [
        "src/commands",
        "src/workflow",
        "src/context",
        "src/run_services",
        "src/prepared_suite",
        "src/bootstrap.rs",
        "src/authoring_validate.rs",
        "src/cluster",
        "src/compose",
        "src/exec",
        "src/io",
        "src/runtime.rs",
    ] {
        assert!(
            !root.join(path).exists(),
            "legacy layout path should not exist anymore: {path}"
        );
    }
}
