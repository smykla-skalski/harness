use std::path::Path;

use super::super::helpers::read_repo_file;

#[test]
fn strip_test_bundle_xattrs_declares_script_input_path() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let build_phases = read_repo_file(
        root,
        "apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildPhases.swift",
    );

    let phase_start = build_phases
        .find("public static func stripTestBundleXattrs() -> TargetScript {")
        .expect("stripTestBundleXattrs phase");
    let phase = &build_phases[phase_start..];

    assert!(
        phase.contains("inputPaths: [")
            && phase.contains("\"$(PROJECT_DIR)/Scripts/strip-test-xattrs.sh\""),
        "stripTestBundleXattrs should declare its script path as an input so Xcode sandboxed build phases can read it"
    );
}
