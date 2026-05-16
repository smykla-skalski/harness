import Foundation

extension AuditRunner {
    /// The audit runner always launches Harness Monitor with
    /// `HARNESS_MONITOR_EXTERNAL_DAEMON=1`, so the mirrored manifest must
    /// live under the matching ownership subdir or the launched app won't
    /// discover it.
    public static let auditTargetOwnershipSegment = "external"

    /// Candidate subdirs to probe for the source manifest in priority order.
    /// `external` matches the live `harness daemon dev` instance the audit
    /// targets; `managed` is a defensive fallback for environments where
    /// only the SMAppService-installed daemon is running and the user
    /// pointed `HARNESS_MONITOR_AUDIT_DAEMON_DATA_HOME` at its data home;
    /// the empty segment preserves backwards-compat with pre-partition
    /// daemons that still write directly under `harness/daemon/`.
    public static let auditSourceOwnershipCandidates = ["external", "managed", ""]

    public struct AuditDaemonManifestSource: Equatable, Sendable {
        public var manifestURL: URL
        public var ownershipSegment: String
    }

    public static func resolveAuditSourceDaemonManifest(
        sourceDataHome: URL,
        fileManager: FileManager = .default
    ) throws -> AuditDaemonManifestSource {
        let daemonRoot = sourceDataHome
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("daemon", isDirectory: true)
        var probed: [String] = []
        for segment in auditSourceOwnershipCandidates {
            let candidate = segment.isEmpty
                ? daemonRoot.appendingPathComponent("manifest.json")
                : daemonRoot
                    .appendingPathComponent(segment, isDirectory: true)
                    .appendingPathComponent("manifest.json")
            probed.append(candidate.path)
            if fileManager.fileExists(atPath: candidate.path) {
                return AuditDaemonManifestSource(
                    manifestURL: candidate,
                    ownershipSegment: segment
                )
            }
        }
        throw Failure(
            message: "External audit daemon manifest missing; probed \(probed.joined(separator: ", "))"
        )
    }
}
