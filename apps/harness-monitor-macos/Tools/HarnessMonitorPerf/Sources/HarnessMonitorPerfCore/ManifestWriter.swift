import Foundation

/// Reads a TSV of capture records (one row per scenario+template) plus a JSON inputs
/// document, then writes the canonical manifest.json the audit pipeline emits today.
public enum ManifestWriter {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Mirrors the TSV layout the audit shell appends per capture:
    /// scenario\\ttemplate\\tduration_seconds\\ttrace_relpath\\texit_status\\tend_reason\\
    /// tpreview_scenario\\tlaunched_process_path\\tdaemon_data_home
    public static func parseCapturesTSV(_ url: URL) throws -> [ManifestBuilder.CaptureRecord] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var records: [ManifestBuilder.CaptureRecord] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 9 else {
                throw Failure(message: "capture row has \(fields.count) fields, expected 9: \(line)")
            }
            records.append(.init(
                scenario: fields[0],
                template: fields[1],
                durationSeconds: Int(fields[2]) ?? 0,
                traceRelpath: fields[3],
                exitStatus: Int(fields[4]) ?? 0,
                endReason: fields[5],
                previewScenario: fields[6],
                launchedProcessPath: fields[7],
                daemonDataHome: fields[8]
            ))
        }
        return records
    }

    /// Decoded JSON inputs document used to build a manifest. The audit shell composes this
    /// blob via jq and pipes it in. `default_environment` and `launch_arguments` are supplied
    /// separately (as repeated flags) so the shell never needs a split/map/reduce jq pipeline.
    public struct InputsDocument: Codable {
        public var label: String
        public var runID: String
        public var createdAtUTC: String
        public var git: ManifestBuilder.GitProvenance
        public var system: ManifestBuilder.SystemInfo
        public var targets: ManifestBuilder.Targets
        public var buildProvenance: ManifestBuilder.BuildProvenance
        public var selectedScenarios: [String]

        enum CodingKeys: String, CodingKey {
            case label
            case runID = "run_id"
            case createdAtUTC = "created_at_utc"
            case git
            case system
            case targets
            case buildProvenance = "build_provenance"
            case selectedScenarios = "selected_scenarios"
        }
    }

    /// Parses repeated `KEY=VALUE` strings into a dictionary. The audit shell already has
    /// these as `$UI_TESTS_ENV` etc. environment-style strings, so passing them as flags
    /// avoids any string-splitting jq pipeline.
    public static func parseEnvironmentPairs(_ pairs: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for raw in pairs {
            guard let equalsIndex = raw.firstIndex(of: "=") else {
                throw Failure(message: "environment pair missing '=': \(raw)")
            }
            let key = String(raw[..<equalsIndex])
            let value = String(raw[raw.index(after: equalsIndex)...])
            result[key] = value
        }
        return result
    }

    @discardableResult
    public static func write(
        inputsJSON: URL,
        capturesTSV: URL,
        environmentPairs: [String],
        launchArguments: [String],
        output: URL
    ) throws -> ManifestBuilder.Manifest {
        let inputsData = try Data(contentsOf: inputsJSON)
        let inputs = try JSONDecoder().decode(InputsDocument.self, from: inputsData)
        let captures = try parseCapturesTSV(capturesTSV)
        let environment = try parseEnvironmentPairs(environmentPairs)

        let builderInputs = ManifestBuilder.Inputs(
            label: inputs.label,
            runID: inputs.runID,
            createdAtUTC: inputs.createdAtUTC,
            git: inputs.git,
            system: inputs.system,
            targets: inputs.targets,
            buildProvenance: inputs.buildProvenance,
            defaultEnvironment: environment,
            launchArguments: launchArguments,
            selectedScenarios: inputs.selectedScenarios,
            captureRecords: captures
        )
        let manifest = ManifestBuilder.build(builderInputs)
        try ManifestBuilder.write(manifest, to: output)
        return manifest
    }
}

/// Verifies that an existing `manifest.json` records a clean build for `expectedCommit`.
/// Mirrors run-instruments-audit-from-ref.sh:133-174.
public enum ManifestVerifier {
    public struct Failure: Error, CustomStringConvertible {
        public let messages: [String]
        public var description: String { messages.joined(separator: "\n") }
    }

    public static func verify(manifest manifestURL: URL, expectedCommit: String) throws {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw Failure(messages: ["manifest.json not found at \(manifestURL.path)"])
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: data)
        let git = manifest["git"] ?? .object([:])
        let targets = manifest["targets"] ?? .object([:])
        let host = manifest["build_provenance"]?["host"] ?? .object([:])

        var errors: [String] = []
        if git["commit"]?.stringValue != expectedCommit {
            errors.append(
                "manifest git.commit=\(git["commit"]?.stringValue ?? "nil") does not match expected \(expectedCommit)"
            )
        }
        if case .bool(false) = git["dirty"] ?? .null {
            // OK
        } else {
            errors.append("manifest git.dirty must be false, got \(describe(git["dirty"]))")
        }
        if (git["workspace_fingerprint"]?.stringValue ?? "").isEmpty {
            errors.append("manifest git.workspace_fingerprint is missing")
        }
        if host["embedded_commit"]?.stringValue != expectedCommit {
            errors.append(
                "manifest host embedded_commit=\(host["embedded_commit"]?.stringValue ?? "nil") does not match expected \(expectedCommit)"
            )
        }
        let embeddedDirty = host["embedded_dirty"]?.stringValue ?? ""
        if embeddedDirty != "false" {
            errors.append("manifest host embedded_dirty must be false, got '\(embeddedDirty)'")
        }
        if (host["binary_sha256"]?.stringValue ?? "").isEmpty {
            errors.append("manifest host binary_sha256 is missing")
        }
        if (targets["staged_host_bundle_id"]?.stringValue ?? "").isEmpty {
            errors.append("manifest staged_host_bundle_id is missing")
        }
        if !errors.isEmpty { throw Failure(messages: errors) }
    }

    private static func describe(_ value: JSONValue?) -> String {
        guard let value else { return "nil" }
        switch value {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return "'\(v)'"
        case .array, .object: return "<complex>"
        }
    }
}
