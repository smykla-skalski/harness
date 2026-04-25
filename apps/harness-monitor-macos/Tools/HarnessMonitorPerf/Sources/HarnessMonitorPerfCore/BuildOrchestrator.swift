import CryptoKit
import Foundation

/// Drives the xcodebuild Release builds for the audit pipeline and inspects build provenance
/// plists embedded in the resulting bundles. Mirrors build_release_targets, purge_release_products,
/// release_products_are_current, bundle_provenance_value in run-instruments-audit.sh.
public enum BuildOrchestrator {
    public static let buildCommitKey = "HarnessMonitorBuildGitCommit"
    public static let buildDirtyKey = "HarnessMonitorBuildGitDirty"
    public static let buildWorkspaceFingerprintKey = "HarnessMonitorBuildWorkspaceFingerprint"
    public static let buildStartedAtUTCKey = "HarnessMonitorBuildStartedAtUTC"
    public static let buildProvenanceResource = "HarnessMonitorBuildProvenance.plist"

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public struct BuildInputs {
        public var xcodebuildRunner: URL
        public var projectPath: URL
        public var derivedDataPath: URL
        public var destination: String
        public var arch: String
        public var shippingScheme: String
        public var hostScheme: String
        public var buildShipping: Bool
        public var forceClean: Bool
        public var skipDaemonBundle: Bool
        public var daemonCargoTargetDir: URL
        public var gitCommit: String
        public var gitDirty: String
        public var workspaceFingerprint: String
        public var buildStartedAtUTC: String

        public init(
            xcodebuildRunner: URL, projectPath: URL, derivedDataPath: URL,
            destination: String, arch: String, shippingScheme: String, hostScheme: String,
            buildShipping: Bool, forceClean: Bool, skipDaemonBundle: Bool,
            daemonCargoTargetDir: URL,
            gitCommit: String, gitDirty: String,
            workspaceFingerprint: String, buildStartedAtUTC: String
        ) {
            self.xcodebuildRunner = xcodebuildRunner
            self.projectPath = projectPath
            self.derivedDataPath = derivedDataPath
            self.destination = destination
            self.arch = arch
            self.shippingScheme = shippingScheme
            self.hostScheme = hostScheme
            self.buildShipping = buildShipping
            self.forceClean = forceClean
            self.skipDaemonBundle = skipDaemonBundle
            self.daemonCargoTargetDir = daemonCargoTargetDir
            self.gitCommit = gitCommit
            self.gitDirty = gitDirty
            self.workspaceFingerprint = workspaceFingerprint
            self.buildStartedAtUTC = buildStartedAtUTC
        }
    }

    public static func purgeReleaseProducts(hostAppPath: URL, shippingAppPath: URL) {
        let fm = FileManager.default
        for url in [
            hostAppPath, hostAppPath.appendingPathExtension("dSYM"),
            shippingAppPath, shippingAppPath.appendingPathExtension("dSYM"),
        ] {
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    public static func bundleProvenanceValue(bundle: URL, key: String) -> String {
        let plist = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(buildProvenanceResource)
        return PlistAccessor.value(at: plist, key: key) ?? ""
    }

    public static func bundleMatchesProvenance(
        bundle: URL,
        expectedCommit: String,
        expectedDirty: String,
        expectedWorkspaceFingerprint: String
    ) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundle.path) else { return false }
        return bundleProvenanceValue(bundle: bundle, key: buildCommitKey) == expectedCommit
            && bundleProvenanceValue(bundle: bundle, key: buildDirtyKey) == expectedDirty
            && bundleProvenanceValue(bundle: bundle, key: buildWorkspaceFingerprintKey) == expectedWorkspaceFingerprint
    }

    public static func releaseProductsCurrent(
        hostAppPath: URL, hostBinaryPath: URL,
        shippingAppPath: URL, shippingBinaryPath: URL,
        buildShipping: Bool,
        gitCommit: String, gitDirty: String, workspaceFingerprint: String
    ) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hostBinaryPath.path) else { return false }
        guard bundleMatchesProvenance(
            bundle: hostAppPath, expectedCommit: gitCommit,
            expectedDirty: gitDirty, expectedWorkspaceFingerprint: workspaceFingerprint
        ) else { return false }
        if buildShipping {
            guard fm.fileExists(atPath: shippingBinaryPath.path) else { return false }
            guard bundleMatchesProvenance(
                bundle: shippingAppPath, expectedCommit: gitCommit,
                expectedDirty: gitDirty, expectedWorkspaceFingerprint: workspaceFingerprint
            ) else { return false }
        }
        return true
    }

    public static func buildReleaseTargets(_ inputs: BuildInputs) throws {
        let common = [
            "ARCHS=\(inputs.arch)",
            "ONLY_ACTIVE_ARCH=YES",
            "ENABLE_CODE_COVERAGE=NO",
            "CLANG_COVERAGE_MAPPING=NO",
            "GCC_GENERATE_TEST_COVERAGE_FILES=NO",
            "COMPILER_INDEX_STORE_ENABLE=NO",
        ]
        let daemonBundleEnv: [String]
        if inputs.skipDaemonBundle {
            daemonBundleEnv = ["HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=1"]
        } else {
            try FileManager.default.createDirectory(
                at: inputs.daemonCargoTargetDir, withIntermediateDirectories: true
            )
            daemonBundleEnv = ["CARGO_TARGET_DIR=\(inputs.daemonCargoTargetDir.path)"]
        }

        if inputs.forceClean {
            if inputs.buildShipping {
                try invokeXcodebuild(inputs, scheme: inputs.shippingScheme, action: "clean", common: common, daemonBundleEnv: nil)
            }
            try invokeXcodebuild(inputs, scheme: inputs.hostScheme, action: "clean", common: common, daemonBundleEnv: nil)
        }

        if inputs.buildShipping {
            try invokeXcodebuild(inputs, scheme: inputs.shippingScheme, action: "build", common: common, daemonBundleEnv: daemonBundleEnv)
        }
        try invokeXcodebuild(inputs, scheme: inputs.hostScheme, action: "build", common: common, daemonBundleEnv: daemonBundleEnv)
    }

    private static func invokeXcodebuild(
        _ inputs: BuildInputs,
        scheme: String, action: String,
        common: [String], daemonBundleEnv: [String]?
    ) throws {
        var arguments: [String] = [
            "-project", inputs.projectPath.path,
            "-scheme", scheme,
            "-configuration", "Release",
            "-derivedDataPath", inputs.derivedDataPath.path,
            "-destination", inputs.destination,
            action,
        ]
        arguments += common
        if let daemonBundleEnv {
            arguments += daemonBundleEnv
            arguments += [
                "HARNESS_MONITOR_BUILD_GIT_COMMIT=\(inputs.gitCommit)",
                "HARNESS_MONITOR_BUILD_GIT_DIRTY=\(inputs.gitDirty)",
                "HARNESS_MONITOR_BUILD_WORKSPACE_FINGERPRINT=\(inputs.workspaceFingerprint)",
                "HARNESS_MONITOR_BUILD_STARTED_AT_UTC=\(inputs.buildStartedAtUTC)",
            ]
        }
        arguments += ["CODE_SIGNING_ALLOWED=NO", "-quiet"]
        let result = try ProcessRunner.run(inputs.xcodebuildRunner.path, arguments: arguments)
        if result.exitStatus != 0 {
            throw Failure(
                message: "xcodebuild \(scheme) \(action) failed (\(result.exitStatus)): \(result.stderrString)"
            )
        }
    }

    public static func binarySHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func binaryMtimeUTC(_ url: URL) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attrs[.modificationDate] as? Date else {
            throw Failure(message: "no modificationDate for \(url.path)")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
