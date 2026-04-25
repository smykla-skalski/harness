import Foundation

/// Builds `manifest.json` for an audit run. Mirrors the python heredoc in
/// run-instruments-audit.sh (lines ~1170-1354) so the JSON shape is preserved.
public enum ManifestBuilder {
    public struct GitProvenance: Codable, Equatable {
        public var commit: String
        public var dirty: Bool
        public var workspaceFingerprint: String
        public var buildStartedAtUTC: String

        enum CodingKeys: String, CodingKey {
            case commit
            case dirty
            case workspaceFingerprint = "workspace_fingerprint"
            case buildStartedAtUTC = "build_started_at_utc"
        }
    }

    public struct SystemInfo: Codable, Equatable {
        public var xcodeVersion: String
        public var xctraceVersion: String
        public var macosVersion: String
        public var macosBuild: String
        public var arch: String

        enum CodingKeys: String, CodingKey {
            case xcodeVersion = "xcode_version"
            case xctraceVersion = "xctrace_version"
            case macosVersion = "macos_version"
            case macosBuild = "macos_build"
            case arch
        }
    }

    public struct Targets: Codable, Equatable {
        public var project: String
        public var shippingScheme: String
        public var hostScheme: String
        public var shippingAppPath: String
        public var hostAppPath: String
        public var hostBundleID: String
        public var stagedHostAppPath: String
        public var stagedHostBinaryPath: String
        public var stagedHostBundleID: String

        enum CodingKeys: String, CodingKey {
            case project
            case shippingScheme = "shipping_scheme"
            case hostScheme = "host_scheme"
            case shippingAppPath = "shipping_app_path"
            case hostAppPath = "host_app_path"
            case hostBundleID = "host_bundle_id"
            case stagedHostAppPath = "staged_host_app_path"
            case stagedHostBinaryPath = "staged_host_binary_path"
            case stagedHostBundleID = "staged_host_bundle_id"
        }
    }

    public struct BuildProvenance: Codable, Equatable {
        public var auditDaemonBundle: AuditDaemonBundle
        public var host: BinaryProvenance
        public var shipping: ShippingProvenance

        enum CodingKeys: String, CodingKey {
            case auditDaemonBundle = "audit_daemon_bundle"
            case host
            case shipping
        }
    }

    public struct AuditDaemonBundle: Codable, Equatable {
        public var requestedSkip: Bool
        public var mode: String
        public var cargoTargetDir: String

        enum CodingKeys: String, CodingKey {
            case requestedSkip = "requested_skip"
            case mode
            case cargoTargetDir = "cargo_target_dir"
        }
    }

    public struct BinaryProvenance: Codable, Equatable {
        public var embeddedCommit: String
        public var embeddedDirty: String
        public var embeddedWorkspaceFingerprint: String
        public var embeddedStartedAtUTC: String
        public var binarySHA256: String
        public var bundleSHA256: String
        public var binaryMtimeUTC: String

        enum CodingKeys: String, CodingKey {
            case embeddedCommit = "embedded_commit"
            case embeddedDirty = "embedded_dirty"
            case embeddedWorkspaceFingerprint = "embedded_workspace_fingerprint"
            case embeddedStartedAtUTC = "embedded_started_at_utc"
            case binarySHA256 = "binary_sha256"
            case bundleSHA256 = "bundle_sha256"
            case binaryMtimeUTC = "binary_mtime_utc"
        }
    }

    public struct ShippingProvenance: Codable, Equatable {
        public var built: Bool
        public var embeddedCommit: String
        public var embeddedDirty: String
        public var embeddedWorkspaceFingerprint: String
        public var embeddedStartedAtUTC: String
        public var binarySHA256: String
        public var bundleSHA256: String
        public var binaryMtimeUTC: String

        enum CodingKeys: String, CodingKey {
            case built
            case embeddedCommit = "embedded_commit"
            case embeddedDirty = "embedded_dirty"
            case embeddedWorkspaceFingerprint = "embedded_workspace_fingerprint"
            case embeddedStartedAtUTC = "embedded_started_at_utc"
            case binarySHA256 = "binary_sha256"
            case bundleSHA256 = "bundle_sha256"
            case binaryMtimeUTC = "binary_mtime_utc"
        }
    }

    public struct Templates: Codable, Equatable, Sendable {
        public var swiftui: [String]
        public var allocations: [String]
    }

    public struct CaptureRecord: Equatable {
        public var scenario: String
        public var template: String
        public var durationSeconds: Int
        public var traceRelpath: String
        public var exitStatus: Int
        public var endReason: String
        public var previewScenario: String
        public var launchedProcessPath: String
        public var daemonDataHome: String
    }

    public struct Capture: Codable, Equatable {
        public var scenario: String
        public var template: String
        public var durationSeconds: Int
        public var traceRelpath: String
        public var exitStatus: Int
        public var endReason: String
        public var previewScenario: String
        public var launchedProcessPath: String
        public var environment: [String: String]
        public var launchArguments: [String]

        enum CodingKeys: String, CodingKey {
            case scenario
            case template
            case durationSeconds = "duration_seconds"
            case traceRelpath = "trace_relpath"
            case exitStatus = "exit_status"
            case endReason = "end_reason"
            case previewScenario = "preview_scenario"
            case launchedProcessPath = "launched_process_path"
            case environment
            case launchArguments = "launch_arguments"
        }
    }

    public struct Manifest: Codable, Equatable {
        public var label: String
        public var runID: String
        public var createdAtUTC: String
        public var git: GitProvenance
        public var system: SystemInfo
        public var targets: Targets
        public var buildProvenance: BuildProvenance
        public var templates: Templates
        public var defaultEnvironment: [String: String]
        public var launchArguments: [String]
        public var selectedScenarios: [String]
        public var captures: [Capture]

        enum CodingKeys: String, CodingKey {
            case label
            case runID = "run_id"
            case createdAtUTC = "created_at_utc"
            case git
            case system
            case targets
            case buildProvenance = "build_provenance"
            case templates
            case defaultEnvironment = "default_environment"
            case launchArguments = "launch_arguments"
            case selectedScenarios = "selected_scenarios"
            case captures
        }
    }

    public struct Inputs {
        public var label: String
        public var runID: String
        public var createdAtUTC: String
        public var git: GitProvenance
        public var system: SystemInfo
        public var targets: Targets
        public var buildProvenance: BuildProvenance
        public var defaultEnvironment: [String: String]
        public var launchArguments: [String]
        public var selectedScenarios: [String]
        public var captureRecords: [CaptureRecord]

        public init(
            label: String, runID: String, createdAtUTC: String,
            git: GitProvenance, system: SystemInfo, targets: Targets,
            buildProvenance: BuildProvenance,
            defaultEnvironment: [String: String], launchArguments: [String],
            selectedScenarios: [String], captureRecords: [CaptureRecord]
        ) {
            self.label = label
            self.runID = runID
            self.createdAtUTC = createdAtUTC
            self.git = git
            self.system = system
            self.targets = targets
            self.buildProvenance = buildProvenance
            self.defaultEnvironment = defaultEnvironment
            self.launchArguments = launchArguments
            self.selectedScenarios = selectedScenarios
            self.captureRecords = captureRecords
        }
    }

    public static let defaultTemplates = Templates(
        swiftui: [
            "launch-dashboard",
            "select-session-cockpit",
            "refresh-and-search",
            "sidebar-overflow-search",
            "timeline-burst",
            "toast-overlay-churn",
            "offline-cached-open",
        ],
        allocations: [
            "settings-backdrop-cycle",
            "settings-background-cycle",
            "offline-cached-open",
        ]
    )

    public static func build(_ inputs: Inputs) -> Manifest {
        let captures = inputs.captureRecords.map { record -> Capture in
            var environment = inputs.defaultEnvironment
            environment["HARNESS_DAEMON_DATA_HOME"] = record.daemonDataHome
            environment["HARNESS_MONITOR_PREVIEW_SCENARIO"] = record.previewScenario
            environment["HARNESS_MONITOR_PERF_SCENARIO"] = record.scenario
            return Capture(
                scenario: record.scenario,
                template: record.template,
                durationSeconds: record.durationSeconds,
                traceRelpath: record.traceRelpath,
                exitStatus: record.exitStatus,
                endReason: record.endReason,
                previewScenario: record.previewScenario,
                launchedProcessPath: record.launchedProcessPath,
                environment: environment,
                launchArguments: inputs.launchArguments
            )
        }

        return Manifest(
            label: inputs.label,
            runID: inputs.runID,
            createdAtUTC: inputs.createdAtUTC,
            git: inputs.git,
            system: inputs.system,
            targets: inputs.targets,
            buildProvenance: inputs.buildProvenance,
            templates: defaultTemplates,
            defaultEnvironment: inputs.defaultEnvironment,
            launchArguments: inputs.launchArguments,
            selectedScenarios: inputs.selectedScenarios,
            captures: captures
        )
    }

    public static func write(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }
}
