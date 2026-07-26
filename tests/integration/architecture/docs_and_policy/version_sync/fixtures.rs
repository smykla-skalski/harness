use std::collections::HashSet;
use std::process::Command;
use std::{fs, path::Path};

use serde_json::Value;

use tempfile::{TempDir, tempdir};

pub(super) const STALE_MONITOR_PBXPROJ_FIXTURE: &str = "\
// !$*UTF8*$!\n\
{\n\
\tarchiveVersion = 1;\n\
\tclasses = {\n\
\t};\n\
\tobjectVersion = 55;\n\
\tobjects = {\n\
\n\
/* Begin PBXNativeTarget section */\n\
\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* HarnessMonitor */ = {\n\
\t\t\tisa = PBXNativeTarget;\n\
\t\t\tbuildConfigurationList = BBBBBBBBBBBBBBBBBBBBBBBB /* Build configuration list for PBXNativeTarget \"HarnessMonitor\" */;\n\
\t\t\tbuildPhases = (\n\
\t\t\t);\n\
\t\t\tbuildRules = (\n\
\t\t\t);\n\
\t\t\tdependencies = (\n\
\t\t\t);\n\
\t\t\tname = HarnessMonitor;\n\
\t\t\tproductName = HarnessMonitor;\n\
\t\t\tproductReference = CCCCCCCCCCCCCCCCCCCCCCCC /* HarnessMonitor.app */;\n\
\t\t\tproductType = \"com.apple.product-type.application\";\n\
\t\t};\n\
/* End PBXNativeTarget section */\n\
\n\
/* Begin PBXProject section */\n\
\t\tDDDDDDDDDDDDDDDDDDDDDDDD /* Project object */ = {\n\
\t\t\tisa = PBXProject;\n\
\t\t\tattributes = {\n\
\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\
\t\t\t};\n\
\t\t\tbuildConfigurationList = EEEEEEEEEEEEEEEEEEEEEEEE /* Build configuration list for PBXProject \"HarnessMonitor\" */;\n\
\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\
\t\t\tdevelopmentRegion = en;\n\
\t\t\thasScannedForEncodings = 0;\n\
\t\t\tknownRegions = (\n\
\t\t\t\ten,\n\
\t\t\t);\n\
\t\t\tmainGroup = FFFFFFFFFFFFFFFFFFFFFFFF;\n\
\t\t\tproductRefGroup = GGGGGGGGGGGGGGGGGGGGGGGG /* Products */;\n\
\t\t\tprojectDirPath = \"\";\n\
\t\t\tprojectRoot = \"\";\n\
\t\t\ttargets = (\n\
\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* HarnessMonitor */,\n\
\t\t\t);\n\
\t\t};\n\
/* End PBXProject section */\n\
\t};\n\
\trootObject = DDDDDDDDDDDDDDDDDDDDDDDD /* Project object */;\n\
}\n";

pub(super) const STALE_MONITOR_PBXPROJ_VERSION_FIXTURE: &str = "\
// !$*UTF8*$!\n\
{\n\
\tarchiveVersion = 1;\n\
\tclasses = {\n\
\t};\n\
\tobjectVersion = 55;\n\
\tobjects = {\n\
\n\
/* Begin PBXNativeTarget section */\n\
\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* HarnessMonitor */ = {\n\
\t\t\tisa = PBXNativeTarget;\n\
\t\t\tbuildConfigurationList = BBBBBBBBBBBBBBBBBBBBBBBB /* Build configuration list for PBXNativeTarget \"HarnessMonitor\" */;\n\
\t\t\tbuildPhases = (\n\
\t\t\t);\n\
\t\t\tbuildRules = (\n\
\t\t\t);\n\
\t\t\tdependencies = (\n\
\t\t\t);\n\
\t\t\tname = HarnessMonitor;\n\
\t\t\tproductName = HarnessMonitor;\n\
\t\t\tproductReference = CCCCCCCCCCCCCCCCCCCCCCCC /* HarnessMonitor.app */;\n\
\t\t\tproductType = \"com.apple.product-type.application\";\n\
\t\t};\n\
/* End PBXNativeTarget section */\n\
\n\
/* Begin PBXProject section */\n\
\t\tDDDDDDDDDDDDDDDDDDDDDDDD /* Project object */ = {\n\
\t\t\tisa = PBXProject;\n\
\t\t\tattributes = {\n\
\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\
\t\t\t};\n\
\t\t\tbuildConfigurationList = EEEEEEEEEEEEEEEEEEEEEEEE /* Build configuration list for PBXProject \"HarnessMonitor\" */;\n\
\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\
\t\t\tdevelopmentRegion = en;\n\
\t\t\thasScannedForEncodings = 0;\n\
\t\t\tknownRegions = (\n\
\t\t\t\ten,\n\
\t\t\t);\n\
\t\t\tmainGroup = FFFFFFFFFFFFFFFFFFFFFFFF;\n\
\t\t\tproductRefGroup = GGGGGGGGGGGGGGGGGGGGGGGG /* Products */;\n\
\t\t\tprojectDirPath = \"\";\n\
\t\t\tprojectRoot = \"\";\n\
\t\t\ttargets = (\n\
\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* HarnessMonitor */,\n\
\t\t\t);\n\
\t\t};\n\
/* End PBXProject section */\n\
\n\
/* Begin XCBuildConfiguration section */\n\
\t\tHHHHHHHHHHHHHHHHHHHHHHHH /* Debug */ = {\n\
\t\t\tisa = XCBuildConfiguration;\n\
\t\t\tbuildSettings = {\n\
\t\t\t\tCURRENT_PROJECT_VERSION = 30.14.5;\n\
\t\t\t\tMARKETING_VERSION = 30.14.5;\n\
\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n\
\t\t\t};\n\
\t\t\tname = Debug;\n\
\t\t};\n\
\t\tIIIIIIIIIIIIIIIIIIIIIIII /* Package Debug */ = {\n\
\t\t\tisa = XCBuildConfiguration;\n\
\t\t\tbuildSettings = {\n\
\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n\
\t\t\t\tPRODUCT_NAME = HarnessMonitorRegistry;\n\
\t\t\t};\n\
\t\t\tname = Debug;\n\
\t\t};\n\
/* End XCBuildConfiguration section */\n\
\t};\n\
\trootObject = DDDDDDDDDDDDDDDDDDDDDDDD /* Project object */;\n\
}\n";

pub(super) const MIXED_MONITOR_PBXPROJ_VERSION_FIXTURE: &str = "\
// !$*UTF8*$!\n\
{\n\
\tarchiveVersion = 1;\n\
\tclasses = {\n\
\t};\n\
\tobjectVersion = 55;\n\
\tobjects = {\n\
\n\
/* Begin PBXNativeTarget section */\n\
\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* HarnessMonitor */ = {\n\
\t\t\tisa = PBXNativeTarget;\n\
\t\t\tbuildConfigurationList = BBBBBBBBBBBBBBBBBBBBBBBB /* Build configuration list for PBXNativeTarget \"HarnessMonitor\" */;\n\
\t\t\tbuildPhases = (\n\
\t\t\t);\n\
\t\t\tbuildRules = (\n\
\t\t\t);\n\
\t\t\tdependencies = (\n\
\t\t\t);\n\
\t\t\tname = HarnessMonitor;\n\
\t\t\tproductName = HarnessMonitor;\n\
\t\t\tproductReference = CCCCCCCCCCCCCCCCCCCCCCCC /* HarnessMonitor.app */;\n\
\t\t\tproductType = \"com.apple.product-type.application\";\n\
\t\t};\n\
/* End PBXNativeTarget section */\n\
\n\
/* Begin PBXProject section */\n\
\t\tDDDDDDDDDDDDDDDDDDDDDDDD /* Project object */ = {\n\
\t\t\tisa = PBXProject;\n\
\t\t\tattributes = {\n\
\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\
\t\t\t};\n\
\t\t\tbuildConfigurationList = EEEEEEEEEEEEEEEEEEEEEEEE /* Build configuration list for PBXProject \"HarnessMonitor\" */;\n\
\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\
\t\t\tdevelopmentRegion = en;\n\
\t\t\thasScannedForEncodings = 0;\n\
\t\t\tknownRegions = (\n\
\t\t\t\ten,\n\
\t\t\t);\n\
\t\t\tmainGroup = FFFFFFFFFFFFFFFFFFFFFFFF;\n\
\t\t\tproductRefGroup = GGGGGGGGGGGGGGGGGGGGGGGG /* Products */;\n\
\t\t\tprojectDirPath = \"\";\n\
\t\t\tprojectRoot = \"\";\n\
\t\t\ttargets = (\n\
\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* HarnessMonitor */,\n\
\t\t\t);\n\
\t\t};\n\
/* End PBXProject section */\n\
\n\
/* Begin XCBuildConfiguration section */\n\
\t\tHHHHHHHHHHHHHHHHHHHHHHHH /* Debug */ = {\n\
\t\t\tisa = XCBuildConfiguration;\n\
\t\t\tbuildSettings = {\n\
\t\t\t\tCURRENT_PROJECT_VERSION = 30.15.0;\n\
\t\t\t\tMARKETING_VERSION = 30.15.0;\n\
\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n\
\t\t\t};\n\
\t\t\tname = Debug;\n\
\t\t};\n\
\t\tIIIIIIIIIIIIIIIIIIIIIIII /* Release */ = {\n\
\t\t\tisa = XCBuildConfiguration;\n\
\t\t\tbuildSettings = {\n\
\t\t\t\tCURRENT_PROJECT_VERSION = 30.14.5;\n\
\t\t\t\tMARKETING_VERSION = 30.14.5;\n\
\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n\
\t\t\t};\n\
\t\t\tname = Release;\n\
\t\t};\n\
\t\tJJJJJJJJJJJJJJJJJJJJJJJJ /* Package Debug */ = {\n\
\t\t\tisa = XCBuildConfiguration;\n\
\t\t\tbuildSettings = {\n\
\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n\
\t\t\t\tPRODUCT_NAME = HarnessMonitorRegistry;\n\
\t\t\t};\n\
\t\t\tname = Debug;\n\
\t\t};\n\
/* End XCBuildConfiguration section */\n\
\t};\n\
\trootObject = DDDDDDDDDDDDDDDDDDDDDDDD /* Project object */;\n\
}\n";

/// Every workspace member's manifest, as cargo resolves them.
///
/// `version.sh` walks the members declared in the copied root manifest and
/// aborts on the first one it cannot find, so this list has to match the
/// workspace exactly. Asking cargo rather than reading the TOML is what makes
/// that reliable: cargo defines the manifest format, so no whitespace variant,
/// trailing comment, or glob member can desynchronise the two, and the failure
/// this fixture was written to stop - a member added and never copied - cannot
/// recur.
fn workspace_member_manifests(root: &Path) -> Vec<String> {
    let output = Command::new(env!("CARGO"))
        .args(["metadata", "--format-version", "1", "--no-deps", "--offline"])
        .current_dir(root)
        .output()
        .expect("invoke cargo metadata");
    assert!(
        output.status.success(),
        "cargo metadata failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let metadata: Value = serde_json::from_slice(&output.stdout).expect("cargo metadata json");
    let members: HashSet<&str> = metadata["workspace_members"]
        .as_array()
        .expect("cargo metadata workspace_members")
        .iter()
        .filter_map(Value::as_str)
        .collect();

    metadata["packages"]
        .as_array()
        .expect("cargo metadata packages")
        .iter()
        .filter(|package| {
            package["id"]
                .as_str()
                .is_some_and(|id| members.contains(id))
        })
        .filter_map(|package| package["manifest_path"].as_str())
        .filter_map(|path| Path::new(path).strip_prefix(root).ok())
        .map(|path| path.display().to_string())
        .collect()
}

pub(super) fn setup_version_script_fixture_with_pbxproj(
    root: &Path,
    pbxproj_fixture: &str,
) -> TempDir {
    let fixture_root = tempdir().expect("temporary repo");
    // Every repo-relative path `version.sh` rewrites, which is not derivable
    // without parsing the script; the member manifests below are derived.
    let fixed_paths = [
        "Cargo.toml",
        "Cargo.lock",
        "docs/api/openapi.json",
        "src/observe/output.rs",
        "scripts/version.sh",
        "apps/harness-monitor/Scripts/lib/swift-tool-env.sh",
        "apps/harness-monitor/Scripts/lib/xcode-version.sh",
        "apps/harness-monitor/Scripts/patch-tuist-pbxproj.py",
        "apps/harness-monitor/Tuist/ProjectDescriptionHelpers/BuildSettings.swift",
        "apps/harness-monitor/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist",
    ];

    // Deduplicated because the `.` member and `fixed_paths` both name the root
    // manifest, and copying a file twice hides which list is responsible.
    let mut relative_paths: Vec<String> = fixed_paths
        .into_iter()
        .map(str::to_owned)
        .chain(workspace_member_manifests(root))
        .collect();
    relative_paths.sort_unstable();
    relative_paths.dedup();

    for relative_path in relative_paths {
        let source = root.join(&relative_path);
        let destination = fixture_root.path().join(&relative_path);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).expect("fixture parent");
        }
        fs::copy(source, destination).expect("copy fixture file");
    }

    let generated_project = fixture_root
        .path()
        .join("apps/harness-monitor/HarnessMonitor.xcodeproj");
    fs::create_dir_all(&generated_project).expect("generated project dir");
    fs::write(generated_project.join("project.pbxproj"), pbxproj_fixture)
        .expect("stale generated pbxproj");

    fixture_root
}

pub(super) fn setup_version_script_fixture(root: &Path) -> TempDir {
    setup_version_script_fixture_with_pbxproj(root, STALE_MONITOR_PBXPROJ_VERSION_FIXTURE)
}
