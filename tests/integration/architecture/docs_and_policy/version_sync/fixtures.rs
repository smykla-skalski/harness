use std::{fs, path::Path};

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

pub(super) fn setup_version_script_fixture_with_pbxproj(
    root: &Path,
    pbxproj_fixture: &str,
) -> TempDir {
    let fixture_root = tempdir().expect("temporary repo");
    for relative_path in [
        "Cargo.toml",
        "Cargo.lock",
        "testkit/Cargo.toml",
        "src/observe/output.rs",
        "scripts/version.sh",
        "apps/harness-monitor-macos/Scripts/lib/swift-tool-env.sh",
        "apps/harness-monitor-macos/Scripts/patch-tuist-pbxproj.py",
        "apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift",
        "apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist",
    ] {
        let source = root.join(relative_path);
        let destination = fixture_root.path().join(relative_path);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).expect("fixture parent");
        }
        fs::copy(source, destination).expect("copy fixture file");
    }

    let generated_project = fixture_root
        .path()
        .join("apps/harness-monitor-macos/HarnessMonitor.xcodeproj");
    fs::create_dir_all(&generated_project).expect("generated project dir");
    fs::write(generated_project.join("project.pbxproj"), pbxproj_fixture)
        .expect("stale generated pbxproj");

    fixture_root
}

pub(super) fn setup_version_script_fixture(root: &Path) -> TempDir {
    setup_version_script_fixture_with_pbxproj(root, STALE_MONITOR_PBXPROJ_VERSION_FIXTURE)
}
