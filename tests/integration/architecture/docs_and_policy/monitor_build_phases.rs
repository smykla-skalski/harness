use std::path::Path;

use super::super::helpers::read_repo_file;

fn section_between<'a>(contents: &'a str, start: &str, end: &str) -> &'a str {
    let start_index = contents.find(start).expect(start);
    let tail = &contents[start_index..];
    let end_index = tail.find(end).expect(end);
    &tail[..end_index]
}

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

#[test]
fn previewable_and_app_targets_package_monitor_asset_catalog() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let project = read_repo_file(root, "apps/harness-monitor-macos/Project.swift");

    let previewable = section_between(
        &project,
        "private let uiPreviewableTarget: Target = {",
        "private let previewHostTarget: Target = .target(",
    );
    assert!(
        previewable.contains("resources: [")
            && previewable.contains("\"Sources/HarnessMonitor/Assets.xcassets\""),
        "HarnessMonitorUIPreviewable should package the shared asset catalog so theme colors resolve from the framework bundle"
    );

    let monitor_app = section_between(
        &project,
        "private let monitorAppTarget: Target = .target(",
        "private let uiTestHostSettings: Settings = .settings(",
    );
    assert!(
        monitor_app.contains("resources: [")
            && monitor_app.contains("\"Sources/HarnessMonitor/Assets.xcassets\""),
        "HarnessMonitor should package the shared asset catalog alongside its app resources"
    );
}

#[test]
fn project_base_does_not_pin_monitor_code_sign_identity() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let build_settings = read_repo_file(
        root,
        "apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift",
    );

    assert!(
        !build_settings.contains("\"CODE_SIGN_IDENTITY\":")
            && !build_settings.contains("\"CODE_SIGN_IDENTITY[sdk=macosx*]\":"),
        "BuildSettings.swift should not pin project-wide code signing identities; entitled app targets must own development signing explicitly"
    );
}

#[test]
fn entitled_monitor_targets_pin_development_signing_identity() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let project = read_repo_file(root, "apps/harness-monitor-macos/Project.swift");

    let preview_host = section_between(
        &project,
        "private let previewHostTarget: Target = .target(",
        "private let monitorAppDependencies: [TargetDependency] = {",
    );
    assert!(
        preview_host.contains("\"CODE_SIGN_IDENTITY[sdk=macosx*]\": \"Apple Development\""),
        "HarnessMonitorPreviewHost should pin Apple Development for macOS signing because it carries entitlements"
    );

    let monitor_app = section_between(
        &project,
        "private let monitorAppSettings: Settings = .settings(",
        "private let monitorAppTarget: Target = .target(",
    );
    assert!(
        monitor_app.contains("\"CODE_SIGN_IDENTITY[sdk=macosx*]\": \"Apple Development\""),
        "HarnessMonitor should pin Apple Development for macOS signing because its entitlements require a development certificate"
    );

    let ui_test_host = section_between(
        &project,
        "private let uiTestHostSettings: Settings = .settings(",
        "private let uiTestHostTarget: Target = .target(",
    );
    assert!(
        ui_test_host.contains("\"CODE_SIGN_IDENTITY[sdk=macosx*]\": \"Apple Development\""),
        "HarnessMonitorUITestHost should pin Apple Development for macOS signing because its entitlements require a development certificate"
    );
}

#[test]
fn monitor_app_uses_literal_bundle_identifier_for_capabilities_ui() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let project = read_repo_file(root, "apps/harness-monitor-macos/Project.swift");
    let build_settings = read_repo_file(
        root,
        "apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift",
    );

    let monitor_app = section_between(
        &project,
        "private let monitorAppSettings: Settings = .settings(",
        "private let monitorAppTarget: Target = .target(",
    );
    assert!(
        monitor_app.contains("\"PRODUCT_BUNDLE_IDENTIFIER\": \"io.harnessmonitor.app\""),
        "HarnessMonitor should use a literal PRODUCT_BUNDLE_IDENTIFIER so Xcode Signing & Capabilities shows the concrete app ID instead of an unresolved placeholder"
    );

    assert!(
        !build_settings.contains("\"HARNESS_MONITOR_APP_BUNDLE_ID\":"),
        "BuildSettings.swift should not define HARNESS_MONITOR_APP_BUNDLE_ID once the app target stops routing its bundle identifier through an extra build-setting indirection"
    );
}
