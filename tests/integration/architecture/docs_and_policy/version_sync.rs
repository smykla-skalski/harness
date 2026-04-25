use std::path::Path;

use super::super::helpers::read_repo_file;

#[test]
fn repo_version_surfaces_stay_in_sync() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let cargo_toml = read_repo_file(root, "Cargo.toml");
    let testkit_cargo_toml = read_repo_file(root, "testkit/Cargo.toml");
    let cargo_lock = read_repo_file(root, "Cargo.lock");
    let build_settings = read_repo_file(
        root,
        "apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift",
    );
    let daemon_info_plist = read_repo_file(
        root,
        "apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist",
    );
    let observe_output = read_repo_file(root, "src/observe/output.rs");

    let version_line = cargo_toml
        .lines()
        .find(|line| line.starts_with("version = "))
        .expect("Cargo.toml package version line");
    let version = version_line
        .split('"')
        .nth(1)
        .expect("Cargo.toml package version value");

    assert!(
        testkit_cargo_toml.contains(&format!("version = \"{version}\"")),
        "testkit/Cargo.toml should match Cargo.toml version {version}"
    );
    assert!(
        cargo_lock.contains(&format!("name = \"harness\"\nversion = \"{version}\"")),
        "Cargo.lock harness package entry should match Cargo.toml version {version}"
    );
    assert!(
        cargo_lock.contains(&format!(
            "name = \"harness-testkit\"\nversion = \"{version}\""
        )),
        "Cargo.lock harness-testkit package entry should match Cargo.toml version {version}"
    );
    assert!(
        build_settings.contains(&format!(
            "\"MARKETING_VERSION\": \"{version}\" // VERSION_MARKER_MARKETING"
        )),
        "BuildSettings.swift MARKETING_VERSION should match Cargo.toml version {version}"
    );
    assert!(
        build_settings.contains(&format!(
            "\"CURRENT_PROJECT_VERSION\": \"{version}\", // VERSION_MARKER_CURRENT"
        )),
        "BuildSettings.swift CURRENT_PROJECT_VERSION should match Cargo.toml version {version}"
    );
    assert!(
        daemon_info_plist.contains(&format!(
            "<key>CFBundleShortVersionString</key>\n\t<string>{version}</string>"
        )),
        "daemon Info.plist CFBundleShortVersionString should match Cargo.toml version {version}"
    );
    assert!(
        daemon_info_plist.contains(&format!(
            "<key>CFBundleVersion</key>\n\t<string>{version}</string>"
        )),
        "daemon Info.plist CFBundleVersion should match Cargo.toml version {version}"
    );
    assert!(
        observe_output.contains("env!(\"CARGO_PKG_VERSION\")"),
        "src/observe/output.rs should source SARIF driver.version from env!(\"CARGO_PKG_VERSION\")"
    );
}

#[test]
fn docs_describe_automatic_version_sync_workflow() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let agents = read_repo_file(root, "AGENTS.md");
    let claude = read_repo_file(root, "CLAUDE.md");
    let readme = read_repo_file(root, "README.md");
    let monitor_readme = read_repo_file(root, "apps/harness-monitor-macos/README.md");
    let mise = read_repo_file(root, ".mise.toml");
    let docs = [
        agents.as_str(),
        claude.as_str(),
        readme.as_str(),
        monitor_readme.as_str(),
        mise.as_str(),
    ];

    super::super::helpers::assert_docs_contain_needles(
        &docs,
        "version workflow docs should mention",
        &[
            "./scripts/version.sh set <version>",
            "mise run version:sync",
            "mise run version:check",
        ],
    );

    assert!(
        !agents.contains("Manual bump surfaces for harness:"),
        "AGENTS.md should describe the automatic version sync workflow instead of manual bump surfaces"
    );
    assert!(
        !claude.contains("Manual bump surfaces for harness:"),
        "CLAUDE.md should describe the automatic version sync workflow instead of manual bump surfaces"
    );
}

#[test]
fn monitor_generate_script_invokes_tuist_then_post_generate() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let script = read_repo_file(root, "apps/harness-monitor-macos/Scripts/generate.sh");
    let post_generate = read_repo_file(
        root,
        "apps/harness-monitor-macos/Scripts/post-generate.sh",
    );

    let tuist_index = script
        .rfind("tuist")
        .expect("generate.sh should invoke tuist");
    let post_index = script
        .rfind("post-generate.sh")
        .expect("generate.sh should run post-generate.sh");
    assert!(
        post_index > tuist_index,
        "generate.sh should run post-generate.sh after tuist generate"
    );
    assert!(
        post_generate.contains("scripts/version.sh") || post_generate.contains("version:sync"),
        "post-generate.sh should sync monitor versions"
    );
}
