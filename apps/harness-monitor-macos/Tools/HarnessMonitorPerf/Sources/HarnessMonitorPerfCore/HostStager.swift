import Foundation

/// Stages a copy of the UI test host into a stable, audit-only path so xctrace records the
/// expected bundle. Mirrors stage_launch_host + strip_app_attrs in run-instruments-audit.sh.
public enum HostStager {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public struct Result {
        public let stagedAppPath: URL
        public let stagedBinaryPath: URL
        public let stagedBundleID: String
    }

    public static func purgeLegacyLaunchHosts(in runsRoot: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runsRoot.path) else { return }
        let entries = try fm.contentsOfDirectory(at: runsRoot, includingPropertiesForKeys: nil)
        for run in entries {
            let legacy = run.appendingPathComponent("launch-host", isDirectory: true)
            if fm.fileExists(atPath: legacy.path) {
                try? fm.removeItem(at: legacy)
            }
        }
    }

    public static func stage(
        hostAppPath: URL,
        stageRoot: URL,
        stagedBundleName: String = "Harness Monitor UI Testing.app",
        stagedBundleID: String,
        stagedBinaryName: String = "Harness Monitor UI Testing"
    ) throws -> Result {
        let fm = FileManager.default
        let stagedApp = stageRoot.appendingPathComponent(stagedBundleName, isDirectory: true)
        let stagedBinary = stagedApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(stagedBinaryName)

        if fm.fileExists(atPath: stageRoot.path) {
            try fm.removeItem(at: stageRoot)
        }
        try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)

        let dittoResult = try ProcessRunner.run(
            "/usr/bin/ditto",
            arguments: [hostAppPath.path, stagedApp.path]
        )
        guard dittoResult.exitStatus == 0 else {
            throw Failure(message: "ditto failed: \(String(data: dittoResult.stderr, encoding: .utf8) ?? "")")
        }

        stripGatekeeperAttributes(stagedApp)

        let infoPlist = stagedApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        try PlistAccessor.upsertString(at: infoPlist, key: "CFBundleIdentifier", value: stagedBundleID)
        try PlistAccessor.upsertBool(at: infoPlist, key: "LSUIElement", value: true)

        return Result(stagedAppPath: stagedApp, stagedBinaryPath: stagedBinary, stagedBundleID: stagedBundleID)
    }

    public static func stripGatekeeperAttributes(_ url: URL) {
        for attr in ["com.apple.provenance", "com.apple.quarantine"] {
            _ = try? ProcessRunner.run(
                "/usr/bin/xattr",
                arguments: ["-dr", attr, url.path]
            )
        }
    }
}
