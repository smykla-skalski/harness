import ProjectDescription

public enum BuildPhases {
    public static func bundleDaemonAgent() -> TargetScript {
        .post(
            script: """
            /bin/bash "$PROJECT_DIR/Scripts/bundle-daemon-agent.sh"
            """,
            name: "Bundle Daemon Agent",
            inputPaths: [
                "$(PROJECT_DIR)/../../Cargo.toml",
                "$(PROJECT_DIR)/../../Cargo.lock",
                "$(PROJECT_DIR)/HarnessMonitorDaemon.entitlements",
                "$(PROJECT_DIR)/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist",
                "$(PROJECT_DIR)/Resources/LaunchAgents/io.harnessmonitor.daemon.plist",
                "$(PROJECT_DIR)/Scripts/bundle-daemon-agent.sh"
            ],
            outputPaths: [
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/harness",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/harness.cstemp",
                "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/io.harnessmonitor.daemon.plist"
            ],
            basedOnDependencyAnalysis: false
        )
    }

    public enum ProvenanceVariant {
        case monitorApp
        case uiTestHost
    }

    public static func clearGatekeeperMetadata(variant: ProvenanceVariant) -> TargetScript {
        let inputPathStrings: [String]
        let pythonIncludes: String
        switch variant {
        case .monitorApp:
            inputPathStrings = [
                "$(PROJECT_DIR)/HarnessMonitor.entitlements",
                "$(PROJECT_DIR)/HarnessMonitorDaemon.entitlements",
                "$(PROJECT_DIR)/HarnessMonitor.xcodeproj/project.pbxproj",
                "$(PROJECT_DIR)/Resources",
                "$(PROJECT_DIR)/Scripts/bundle-daemon-agent.sh",
                "$(PROJECT_DIR)/Scripts/run-xcode-build-server.sh",
                "$(PROJECT_DIR)/Sources/HarnessMonitor",
                "$(PROJECT_DIR)/Sources/HarnessMonitorKit"
            ]
            pythonIncludes = """
                    root / "HarnessMonitor.entitlements",
                    root / "HarnessMonitorDaemon.entitlements",
                    root / "HarnessMonitor.xcodeproj" / "project.pbxproj",
                    root / "Resources",
                    root / "Scripts" / "bundle-daemon-agent.sh",
                    root / "Scripts" / "run-xcode-build-server.sh",
                    root / "Sources" / "HarnessMonitor",
                    root / "Sources" / "HarnessMonitorKit",
                    root / "Sources" / "HarnessMonitorUIPreviewable",
            """
        case .uiTestHost:
            inputPathStrings = [
                "$(PROJECT_DIR)/HarnessMonitor.entitlements",
                "$(PROJECT_DIR)/HarnessMonitorUITestHost.entitlements",
                "$(PROJECT_DIR)/HarnessMonitorDaemon.entitlements",
                "$(PROJECT_DIR)/HarnessMonitor.xcodeproj/project.pbxproj",
                "$(PROJECT_DIR)/Resources",
                "$(PROJECT_DIR)/Scripts/bundle-daemon-agent.sh",
                "$(PROJECT_DIR)/Scripts/run-xcode-build-server.sh",
                "$(PROJECT_DIR)/Sources/HarnessMonitor",
                "$(PROJECT_DIR)/Sources/HarnessMonitorKit",
                "$(PROJECT_DIR)/Sources/HarnessMonitorUIPreviewable"
            ]
            pythonIncludes = """
                    root / "HarnessMonitor.entitlements",
                    root / "HarnessMonitorUITestHost.entitlements",
                    root / "HarnessMonitorDaemon.entitlements",
                    root / "HarnessMonitor.xcodeproj" / "project.pbxproj",
                    root / "Resources",
                    root / "Scripts" / "bundle-daemon-agent.sh",
                    root / "Scripts" / "run-xcode-build-server.sh",
                    root / "Sources" / "HarnessMonitor",
                    root / "Sources" / "HarnessMonitorKit",
                    root / "Sources" / "HarnessMonitorUIPreviewable",
            """
        }
        let scriptText = provenanceShellScript(pythonIncludes: pythonIncludes)
        return .post(
            script: scriptText,
            name: "Clear Gatekeeper Metadata",
            inputPaths: inputPathStrings.map { .glob(.path($0)) },
            outputPaths: [
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/HarnessMonitorBuildProvenance.plist"
            ],
            basedOnDependencyAnalysis: false
        )
    }

    public static func stripTestBundleXattrs() -> TargetScript {
        .post(
            script: """
            if [ "${XCODE_RUNNING_FOR_PREVIEWS:-}" = "1" ] || [[ "${BUILD_DIR:-}" == *"/Previews/"* ]]; then
              exit 0
            fi

            strip_attrs() {
              local target_path="$1"
              if [ -e "$target_path" ]; then
                /usr/bin/xattr -dr com.apple.provenance "$target_path" 2>/dev/null || true
                /usr/bin/xattr -dr com.apple.quarantine "$target_path" 2>/dev/null || true
              fi
            }

            strip_attrs "$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

            for runner in "$BUILT_PRODUCTS_DIR"/*-Runner.app; do
              if [ -e "$runner" ]; then
                strip_attrs "$runner"
              fi
            done
            """,
            name: "Clear Gatekeeper Metadata",
            basedOnDependencyAnalysis: false
        )
    }

    private static func provenanceShellScript(pythonIncludes: String) -> String {
        """
        set -eu

        if [ "${XCODE_RUNNING_FOR_PREVIEWS:-}" = "1" ] || [[ "${BUILD_DIR:-}" == *"/Previews/"* ]]; then
          exit 0
        fi

        resolve_repo_root() {
          local candidate="$PROJECT_DIR"
          while [ "$candidate" != "/" ]; do
            if [ -d "$candidate/.git" ]; then
              printf '%s\\n' "$candidate"
              return
            fi
            candidate="$(dirname "$candidate")"
          done
          printf '%s\\n' "$PROJECT_DIR"
        }

        workspace_tree_fingerprint() {
          python3 - "$PROJECT_DIR" <<'PY'
        from __future__ import annotations

        import hashlib
        import sys
        from pathlib import Path

        root = Path(sys.argv[1])
        include_paths = [
        \(pythonIncludes)
        ]
        digest = hashlib.sha256()

        for include_path in include_paths:
            if not include_path.exists():
                continue

            if include_path.is_file():
                file_paths = [include_path]
            else:
                file_paths = sorted(
                    candidate for candidate in include_path.rglob("*") if candidate.is_file()
                )

            for file_path in file_paths:
                relative_path = file_path.relative_to(root).as_posix()
                digest.update(relative_path.encode("utf-8"))
                digest.update(b"\\0")
                with file_path.open("rb") as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(chunk)
                digest.update(b"\\0")

        print(digest.hexdigest())
        PY
        }

        repo_root="$(resolve_repo_root)"
        build_commit="${HARNESS_MONITOR_BUILD_GIT_COMMIT:-}"
        if [ -z "$build_commit" ]; then
          build_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf 'unknown')"
        fi

        build_dirty="${HARNESS_MONITOR_BUILD_GIT_DIRTY:-}"
        if [ -z "$build_dirty" ]; then
          if [ -n "$(git -C "$repo_root" status --short 2>/dev/null || true)" ]; then
            build_dirty="true"
          else
            build_dirty="false"
          fi
        fi

        build_workspace_fingerprint="${HARNESS_MONITOR_BUILD_WORKSPACE_FINGERPRINT:-}"
        if [ -z "$build_workspace_fingerprint" ]; then
          if [ "${ENABLE_USER_SCRIPT_SANDBOXING:-}" = "YES" ]; then
            build_workspace_fingerprint="unavailable-user-script-sandbox"
          else
            build_workspace_fingerprint="$(workspace_tree_fingerprint)"
          fi
        fi

        build_started_at_utc="${HARNESS_MONITOR_BUILD_STARTED_AT_UTC:-}"
        if [ -z "$build_started_at_utc" ]; then
          build_started_at_utc="$(TZ=UTC /bin/date +%Y-%m-%dT%H:%M:%SZ)"
        fi

        write_build_provenance() {
          local provenance_path="${SCRIPT_OUTPUT_FILE_0:-$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/HarnessMonitorBuildProvenance.plist}"
          local resources_dir
          resources_dir="$(dirname "$provenance_path")"

          /bin/mkdir -p "$resources_dir"
          /bin/cat > "$provenance_path" <<EOF
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>HarnessMonitorBuildGitCommit</key>
          <string>${build_commit}</string>
          <key>HarnessMonitorBuildGitDirty</key>
          <string>${build_dirty}</string>
          <key>HarnessMonitorBuildWorkspaceFingerprint</key>
          <string>${build_workspace_fingerprint}</string>
          <key>HarnessMonitorBuildStartedAtUTC</key>
          <string>${build_started_at_utc}</string>
        </dict>
        </plist>
        EOF
        }

        strip_attrs() {
          local target_path="$1"
          if [ -e "$target_path" ]; then
            /usr/bin/xattr -dr com.apple.provenance "$target_path" 2>/dev/null || true
            /usr/bin/xattr -dr com.apple.quarantine "$target_path" 2>/dev/null || true
          fi
        }

        write_build_provenance
        strip_attrs "$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
        """
    }
}
