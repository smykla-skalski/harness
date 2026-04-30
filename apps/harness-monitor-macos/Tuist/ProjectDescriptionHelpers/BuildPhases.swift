import ProjectDescription

public enum BuildPhases {
    private static func scriptPhaseBody(
        projectVariable: String,
        script: String,
        arguments: String = ""
    ) -> String {
        """
        set -euo pipefail
        project_dir="${\(projectVariable):-${PROJECT_DIR:-}}"
        if [ -z "$project_dir" ]; then
          echo "missing project_dir for build phase script \(script)" >&2
          exit 65
        fi
        /bin/sh "$project_dir/Scripts/lib/xcode-build-phase-entry.sh" "$project_dir/Scripts/\(script)"\(arguments)
        """
    }

    public static func daemonBuildPreAction() -> ExecutionAction {
        .executionAction(
            title: "Build harness daemon (parallel)",
            scriptText: scriptPhaseBody(
                projectVariable: "SRCROOT",
                script: "build-daemon-agent.sh"
            ),
            target: .target("HarnessMonitor")
        )
    }

    public static func bundleDaemonAgent() -> TargetScript {
        .post(
            script: scriptPhaseBody(
                projectVariable: "PROJECT_DIR",
                script: "bundle-daemon-agent.sh"
            ),
            name: "Bundle Daemon Agent",
            outputPaths: [
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/harness",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/io.harnessmonitor.daemon.plist"
            ],
            basedOnDependencyAnalysis: false
        )
    }

    public enum ProvenanceVariant: String {
        case monitorApp = "monitor-app"
        case uiTestHost = "ui-test-host"

        var appEntitlementInputPaths: [FileListGlob] {
            switch self {
            case .monitorApp:
                [.glob("$(PROJECT_DIR)/HarnessMonitor.entitlements")]
            case .uiTestHost:
                [.glob("$(PROJECT_DIR)/HarnessMonitorUITestHost.entitlements")]
            }
        }

        var inputPaths: [String] {
            var paths: [String] = [
                "$(PROJECT_DIR)/HarnessMonitorBase.entitlements",
                "$(PROJECT_DIR)/HarnessMonitor.entitlements"
            ]
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

    public static func prepareAppEntitlements(variant: ProvenanceVariant) -> TargetScript {
        .pre(
            script: scriptPhaseBody(
                projectVariable: "PROJECT_DIR",
                script: "copy-app-entitlements.sh",
                arguments: " \(variant.rawValue)"
            ),
            name: "Prepare App Entitlements",
            inputPaths: variant.appEntitlementInputPaths,
            outputPaths: [
                "$(DERIVED_FILE_DIR)/$(TARGET_NAME).codesign.entitlements"
            ],
            basedOnDependencyAnalysis: true
        )
    }

    public static func clearGatekeeperMetadata(variant: ProvenanceVariant) -> TargetScript {
        .post(
            script: scriptPhaseBody(
                projectVariable: "PROJECT_DIR",
                script: "inject-build-provenance.sh",
                arguments: " \(variant.rawValue)"
            ),
            name: "Clear Gatekeeper Metadata",
            outputPaths: [
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/HarnessMonitorBuildProvenance.plist"
            ],
            basedOnDependencyAnalysis: false
        )
    }

    public static func stripTestBundleXattrs() -> TargetScript {
        .post(
            script: scriptPhaseBody(
                projectVariable: "PROJECT_DIR",
                script: "strip-test-xattrs.sh"
            ),
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
