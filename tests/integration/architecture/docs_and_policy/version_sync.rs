use std::{fs, path::Path, process::Command};

use super::super::helpers::read_repo_file;
use fixtures::{
    MIXED_MONITOR_PBXPROJ_VERSION_FIXTURE, STALE_MONITOR_PBXPROJ_FIXTURE,
    STALE_MONITOR_PBXPROJ_VERSION_FIXTURE, setup_version_script_fixture,
    setup_version_script_fixture_with_pbxproj,
};
use tempfile::tempdir;

mod fixtures;

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
    let post_generate = read_repo_file(root, "apps/harness-monitor-macos/Scripts/post-generate.sh");

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

#[test]
fn monitor_pbxproj_stays_on_current_xcode_format() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let post_generate = read_repo_file(root, "apps/harness-monitor-macos/Scripts/post-generate.sh");
    let patcher = read_repo_file(
        root,
        "apps/harness-monitor-macos/Scripts/patch-tuist-pbxproj.py",
    );

    assert!(
        post_generate.contains("HARNESS_MONITOR_PROJECT_OBJECT_VERSION")
            && post_generate.contains("HARNESS_MONITOR_PREFERRED_PROJECT_OBJECT_VERSION"),
        "post-generate.sh should pass the normalized project-format settings into the patcher"
    );
    assert!(
        patcher.contains("preferredProjectObjectVersion")
            && patcher.contains("compatibilityVersion")
            && patcher.contains("LastSwiftUpdateCheck"),
        "patch-tuist-pbxproj.py should normalize current Xcode project metadata"
    );

    let tempdir = tempdir().expect("temporary directory");
    let pbxproj_path = tempdir.path().join("project.pbxproj");
    fs::write(&pbxproj_path, STALE_MONITOR_PBXPROJ_FIXTURE).expect("fixture pbxproj");

    let status = Command::new("/usr/bin/python3")
        .arg(root.join("apps/harness-monitor-macos/Scripts/patch-tuist-pbxproj.py"))
        .env("HARNESS_MONITOR_PBXPROJ", &pbxproj_path)
        .env("HARNESS_MONITOR_LAST_UPGRADE_CHECK", "2640")
        .env("HARNESS_MONITOR_LAST_SWIFT_UPDATE_CHECK", "2640")
        .env("HARNESS_MONITOR_PROJECT_OBJECT_VERSION", "77")
        .env("HARNESS_MONITOR_PREFERRED_PROJECT_OBJECT_VERSION", "77")
        .env("HARNESS_MONITOR_APP_ROOT", tempdir.path())
        .env("HARNESS_MONITOR_REPO_ROOT", tempdir.path())
        .status()
        .expect("patch-tuist-pbxproj.py should execute");
    assert!(
        status.success(),
        "patch-tuist-pbxproj.py should patch stale Tuist pbxproj fixtures"
    );

    let patched = fs::read_to_string(&pbxproj_path).expect("patched pbxproj");
    assert!(
        patched.contains("objectVersion = 77;"),
        "patched pbxproj should use the current project object version"
    );
    assert!(
        patched.contains("preferredProjectObjectVersion = 77;"),
        "patched pbxproj should advertise the current preferred project object version"
    );
    assert!(
        !patched.contains("compatibilityVersion = \"Xcode 14.0\";"),
        "patched pbxproj should remove the stale Xcode 14 compatibilityVersion"
    );
    assert!(
        patched.contains("LastSwiftUpdateCheck = 2640;"),
        "patched pbxproj should track the current Xcode swift update check"
    );
    assert!(
        patched.contains("LastUpgradeCheck = 2640;"),
        "patched pbxproj should track the current Xcode upgrade check"
    );
}

#[test]
fn monitor_pbxproj_version_sync_updates_semver_entries_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let tempdir = tempdir().expect("temporary directory");
    let pbxproj_path = tempdir.path().join("project.pbxproj");
    fs::write(&pbxproj_path, STALE_MONITOR_PBXPROJ_VERSION_FIXTURE).expect("fixture pbxproj");

    let status = Command::new("/usr/bin/python3")
        .arg(root.join("apps/harness-monitor-macos/Scripts/patch-tuist-pbxproj.py"))
        .env("HARNESS_MONITOR_PBXPROJ", &pbxproj_path)
        .env("HARNESS_MONITOR_LAST_UPGRADE_CHECK", "2640")
        .env("HARNESS_MONITOR_LAST_SWIFT_UPDATE_CHECK", "2640")
        .env("HARNESS_MONITOR_PROJECT_OBJECT_VERSION", "77")
        .env("HARNESS_MONITOR_PREFERRED_PROJECT_OBJECT_VERSION", "77")
        .env("HARNESS_MONITOR_MARKETING_VERSION", "30.15.0")
        .env("HARNESS_MONITOR_CURRENT_PROJECT_VERSION", "30.15.0")
        .env("HARNESS_MONITOR_APP_ROOT", tempdir.path())
        .env("HARNESS_MONITOR_REPO_ROOT", tempdir.path())
        .status()
        .expect("patch-tuist-pbxproj.py should execute");

    assert!(
        status.success(),
        "patch-tuist-pbxproj.py should patch stale Tuist pbxproj fixtures"
    );

    let patched = fs::read_to_string(&pbxproj_path).expect("patched pbxproj");
    assert!(
        patched.contains("MARKETING_VERSION = 30.15.0;"),
        "patched pbxproj should sync semver-valued MARKETING_VERSION entries"
    );
    assert!(
        patched.contains("CURRENT_PROJECT_VERSION = 30.15.0;"),
        "patched pbxproj should sync semver-valued CURRENT_PROJECT_VERSION entries"
    );
    assert!(
        patched.contains("CURRENT_PROJECT_VERSION = 1;"),
        "patched pbxproj should preserve non-semver integer CURRENT_PROJECT_VERSION entries"
    );
}

#[test]
fn version_script_check_rejects_stale_generated_monitor_pbxproj_when_present() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let fixture_root = setup_version_script_fixture(root);

    let check = Command::new("/bin/bash")
        .arg(fixture_root.path().join("scripts/version.sh"))
        .arg("check")
        .current_dir(fixture_root.path())
        .output()
        .expect("version.sh check should run");

    assert!(
        !check.status.success(),
        "version.sh check should fail when the generated monitor pbxproj is stale"
    );

    let stderr = String::from_utf8_lossy(&check.stderr);
    assert!(
        stderr.contains("HarnessMonitor.xcodeproj/project.pbxproj"),
        "version.sh check should report the stale generated monitor pbxproj"
    );
}

#[test]
fn version_script_check_rejects_mixed_generated_monitor_pbxproj_versions() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let fixture_root =
        setup_version_script_fixture_with_pbxproj(root, MIXED_MONITOR_PBXPROJ_VERSION_FIXTURE);

    let check = Command::new("/bin/bash")
        .arg(fixture_root.path().join("scripts/version.sh"))
        .arg("check")
        .current_dir(fixture_root.path())
        .output()
        .expect("version.sh check should run");

    assert!(
        !check.status.success(),
        "version.sh check should fail when later generated pbxproj semver entries are stale"
    );
}

#[test]
fn version_script_syncs_generated_monitor_pbxproj_when_present() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let fixture_root = setup_version_script_fixture(root);

    let sync = Command::new("/bin/bash")
        .arg(fixture_root.path().join("scripts/version.sh"))
        .arg("sync")
        .current_dir(fixture_root.path())
        .status()
        .expect("version.sh sync should run");

    assert!(sync.success(), "version.sh sync should succeed");

    let patched = fs::read_to_string(
        fixture_root
            .path()
            .join("apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj"),
    )
    .expect("patched generated pbxproj");
    assert!(
        patched.contains("MARKETING_VERSION = 30.15.0;"),
        "version.sh sync should update generated MARKETING_VERSION entries"
    );
    assert!(
        patched.contains("CURRENT_PROJECT_VERSION = 30.15.0;"),
        "version.sh sync should update generated CURRENT_PROJECT_VERSION entries"
    );
}
