use std::path::Path;

use super::super::helpers::read_repo_file;

#[test]
fn repo_version_surfaces_stay_in_sync() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let cargo_toml = read_repo_file(root, "Cargo.toml");
    let testkit_cargo_toml = read_repo_file(root, "testkit/Cargo.toml");
    let cargo_lock = read_repo_file(root, "Cargo.lock");
    let project_yml = read_repo_file(root, "apps/harness-monitor-macos/project.yml");
    let project_pbxproj = read_repo_file(
        root,
        "apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj",
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
        project_yml.contains(&format!("MARKETING_VERSION: {version}")),
        "apps/harness-monitor-macos/project.yml should match Cargo.toml version {version}"
    );
    assert!(
        project_yml.contains(&format!("CURRENT_PROJECT_VERSION: {version}")),
        "apps/harness-monitor-macos/project.yml CURRENT_PROJECT_VERSION should match Cargo.toml version {version}"
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

    let pbxproj_versions: Vec<_> = project_pbxproj
        .lines()
        .filter_map(|line| {
            line.trim()
                .strip_prefix("MARKETING_VERSION = ")
                .map(|value| value.trim_end_matches(';').to_string())
        })
        .collect();
    assert!(
        !pbxproj_versions.is_empty(),
        "project.pbxproj should contain MARKETING_VERSION entries"
    );
    assert!(
        pbxproj_versions.iter().all(|value| value == version),
        "project.pbxproj MARKETING_VERSION values should all match Cargo.toml version {version}: {pbxproj_versions:?}"
    );

    let pbxproj_build_versions: Vec<_> = project_pbxproj
        .lines()
        .filter_map(|line| {
            line.trim()
                .strip_prefix("CURRENT_PROJECT_VERSION = ")
                .map(|value| value.trim_end_matches(';').to_string())
        })
        .collect();
    assert!(
        !pbxproj_build_versions.is_empty(),
        "project.pbxproj should contain CURRENT_PROJECT_VERSION entries"
    );
    assert!(
        pbxproj_build_versions.iter().all(|value| value == version),
        "project.pbxproj CURRENT_PROJECT_VERSION values should all match Cargo.toml version {version}: {pbxproj_build_versions:?}"
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
fn monitor_project_generation_syncs_versions_after_xcodegen() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let script = read_repo_file(root, "apps/harness-monitor-macos/Scripts/generate-project.sh");
    let xcodegen_index = script
        .find("\"$XCODEGEN_BIN\" generate --spec \"$ROOT/project.yml\" --project \"$ROOT\"")
        .expect("generate-project.sh should invoke xcodegen");
    let sync_index = script
        .rfind("\"$REPO_ROOT/scripts/version.sh\" sync-monitor")
        .expect("generate-project.sh should sync monitor versions");

    assert!(
        sync_index > xcodegen_index,
        "generate-project.sh should sync monitor versions after xcodegen so regenerated project.pbxproj build versions do not drift"
    );
}
