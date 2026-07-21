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

    public static func prepareAppEntitlementsPreAction() -> ExecutionAction {
        .executionAction(
            title: "Prepare app entitlements",
            scriptText: scriptPhaseBody(
                projectVariable: "SRCROOT",
                script: "prepare-app-entitlements.sh"
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
            inputPaths: [
                "$(PROJECT_DIR)/Scripts/lib/xcode-build-phase-entry.sh",
                "$(PROJECT_DIR)/Scripts/bundle-daemon-agent.sh",
                "$(PROJECT_DIR)/Scripts/lib/daemon-bundle-env.sh",
                "$(PROJECT_DIR)/Scripts/lib/daemon-cargo-build.sh",
                "$(PROJECT_DIR)/Scripts/lib/daemon-input-state.py",
                "$(PROJECT_DIR)/Scripts/lib/monitor-lanes.sh",
                "$(PROJECT_DIR)/Scripts/lib/swift-tool-env.sh",
                "$(PROJECT_DIR)/Resources/LaunchAgents/Q498EB36N4.io.harnessmonitor.daemon.plist",
                "$(PROJECT_DIR)/Resources/LaunchAgents/io.harnessmonitor.daemon.managed.plist",
                "$(PROJECT_DIR)/Resources/LaunchAgents/io.harnessmonitor.daemon.plist",
                "$(PROJECT_DIR)/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist",
                "$(PROJECT_DIR)/HarnessMonitorDaemon.entitlements",
                // Read by the daemon-cargo-build invocation-token fast path. The
                // prepare-app-entitlements pre-action stamps it in PROJECT_TEMP_DIR;
                // declare it so the user-script sandbox permits the cmp/cp reads.
                "$(PROJECT_TEMP_DIR)/HarnessMonitor-daemon-build-invocation.id",
                // Read-only here: the fast-path cmp compares this against the token
                // above. This marker is shared by every target that bundles the
                // daemon (HarnessMonitor, HarnessMonitorExternalDaemon,
                // HarnessMonitorUITestHost), so it must stay input-only on each of
                // their phases -- an output declared on more than one target's phase
                // makes Xcode reject the build with "Multiple commands produce" the
                // moment two of them build together (e.g. an XCUITest run). The
                // daemon-build-agent scheme pre-action is the actual writer; it runs
                // once per invocation and isn't sandboxed. When it hasn't run first,
                // the cmp here just misses and daemon-cargo-build.sh falls back to
                // its content-hash freshness check.
                "$(PROJECT_TEMP_DIR)/HarnessMonitor-daemon-staged-ready.id",
                "$(PROJECT_TEMP_DIR)/HarnessMonitor-daemon-staged-ready.id.staging"
            ],
            outputPaths: [
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/harness-daemon",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/harness-daemon.cstemp",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/harness-daemon.staging",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/harness-daemon.staging.cstemp",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/Q498EB36N4.io.harnessmonitor.daemon.plist",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/Q498EB36N4.io.harnessmonitor.daemon.plist.staging",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/io.harnessmonitor.daemon.managed.plist",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/io.harnessmonitor.daemon.plist",
                "$(DERIVED_FILE_DIR)/$(TARGET_NAME)-bundle-daemon-agent.stamp"
            ],
            // Rust compiler inputs are discovered dynamically from Cargo dep-info,
            // so Xcode cannot model the complete input set here. Keep this phase
            // unconditional; the pre-action publishes a same-invocation ready
            // stamp, while fallback builds use one batched content digest.
            basedOnDependencyAnalysis: false
        )
    }

    public enum ProvenanceVariant: String {
        case monitorApp = "monitor-app"
        case uiTestHost = "ui-test-host"

        var inputPaths: [FileListGlob] {
            var paths: [FileListGlob] = [
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
                "$(PROJECT_DIR)/Scripts/prepare-app-entitlements.sh",
                "$(PROJECT_DIR)/Scripts/run-xcode-build-server.sh",
                "$(PROJECT_DIR)/Scripts/lib/swift-package-freshness.sh",
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
            script: scriptPhaseBody(
                projectVariable: "PROJECT_DIR",
                script: "inject-build-provenance.sh",
                arguments: " \(variant.rawValue)"
            ),
            name: "Clear Gatekeeper Metadata",
            inputPaths: variant.inputPaths + ["$(TARGET_BUILD_DIR)/$(FULL_PRODUCT_NAME)"],
            outputPaths: [
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/HarnessMonitorBuildProvenance.plist"
            ],
            basedOnDependencyAnalysis: true
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
