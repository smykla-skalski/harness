import ProjectDescription

public enum BuildPhases {
    public static func daemonBuildPreAction() -> ExecutionAction {
        .executionAction(
            title: "Build harness daemon (parallel)",
            scriptText: """
            set -euo pipefail
            /bin/sh "$SRCROOT/Scripts/lib/xcode-build-phase-entry.sh" "$SRCROOT/Scripts/build-daemon-agent.sh"
            """,
            target: .target("HarnessMonitor")
        )
    }

    public static func bundleDaemonAgent() -> TargetScript {
        .post(
            script: """
            /bin/sh "$PROJECT_DIR/Scripts/lib/xcode-build-phase-entry.sh" "$PROJECT_DIR/Scripts/bundle-daemon-agent.sh"
            """,
            name: "Bundle Daemon Agent",
            inputPaths: [
                "$(PROJECT_DIR)/../../Cargo.toml",
                "$(PROJECT_DIR)/../../Cargo.lock",
                "$(PROJECT_DIR)/../../build.rs",
                "$(PROJECT_DIR)/../../src",
                "$(PROJECT_DIR)/HarnessMonitorDaemon.entitlements",
                "$(PROJECT_DIR)/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist",
                "$(PROJECT_DIR)/Resources/LaunchAgents/io.harnessmonitor.daemon.plist",
                "$(PROJECT_DIR)/Scripts/build-daemon-agent.sh",
                "$(PROJECT_DIR)/Scripts/bundle-daemon-agent.sh",
                "$(PROJECT_DIR)/Scripts/lib/daemon-bundle-env.sh",
                "$(PROJECT_DIR)/Scripts/lib/daemon-cargo-build.sh",
                "$(PROJECT_DIR)/Scripts/lib/swift-tool-env.sh",
                "$(PROJECT_DIR)/Scripts/lib/xcode-build-phase-entry.sh"
            ],
            outputPaths: [
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/harness",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/io.harnessmonitor.daemon.plist"
            ],
            basedOnDependencyAnalysis: true
        )
    }

    public enum ProvenanceVariant: String {
        case monitorApp = "monitor-app"
        case uiTestHost = "ui-test-host"

        var inputPaths: [String] {
            var paths: [String] = ["$(PROJECT_DIR)/HarnessMonitor.entitlements"]
            if self == .uiTestHost {
                paths.append("$(PROJECT_DIR)/HarnessMonitorUITestHost.entitlements")
            }
            paths.append(contentsOf: [
                "$(PROJECT_DIR)/HarnessMonitorDaemon.entitlements",
                "$(PROJECT_DIR)/HarnessMonitor.xcodeproj/project.pbxproj",
                "$(PROJECT_DIR)/Resources",
                "$(PROJECT_DIR)/Scripts/bundle-daemon-agent.sh",
                "$(PROJECT_DIR)/Scripts/inject-build-provenance.sh",
                "$(PROJECT_DIR)/Scripts/run-xcode-build-server.sh",
                "$(PROJECT_DIR)/Scripts/lib/swift-tool-env.sh",
                "$(PROJECT_DIR)/Scripts/lib/xcode-build-phase-entry.sh",
                "$(PROJECT_DIR)/Sources/HarnessMonitor",
                "$(PROJECT_DIR)/Sources/HarnessMonitorKit"
            ])
            if self == .uiTestHost {
                paths.append("$(PROJECT_DIR)/Sources/HarnessMonitorUIPreviewable")
            }
            return paths
        }
    }

    public static func clearGatekeeperMetadata(variant: ProvenanceVariant) -> TargetScript {
        .post(
            script: """
            /bin/sh "$PROJECT_DIR/Scripts/lib/xcode-build-phase-entry.sh" "$PROJECT_DIR/Scripts/inject-build-provenance.sh" \(variant.rawValue)
            """,
            name: "Clear Gatekeeper Metadata",
            inputPaths: variant.inputPaths.map { .glob(.path($0)) },
            outputPaths: [
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/HarnessMonitorBuildProvenance.plist"
            ],
            basedOnDependencyAnalysis: true
        )
    }

    public static func stripTestBundleXattrs() -> TargetScript {
        .post(
            script: """
            /bin/sh "$PROJECT_DIR/Scripts/lib/xcode-build-phase-entry.sh" "$PROJECT_DIR/Scripts/strip-test-xattrs.sh"
            """,
            name: "Clear Gatekeeper Metadata",
            inputPaths: [
                "$(PROJECT_DIR)/Scripts/strip-test-xattrs.sh",
                "$(PROJECT_DIR)/Scripts/lib/swift-tool-env.sh",
                "$(PROJECT_DIR)/Scripts/lib/xcode-build-phase-entry.sh",
                "$(TARGET_BUILD_DIR)/$(FULL_PRODUCT_NAME)"
            ],
            outputPaths: [
                "$(DERIVED_FILE_DIR)/$(TARGET_NAME)-strip-test-xattrs.stamp"
            ],
            basedOnDependencyAnalysis: true
        )
    }
}
