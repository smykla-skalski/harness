import CryptoKit
import Foundation

/// Computes the SHA-256 fingerprint of the Harness Monitor source surface that ships into the
/// build provenance plist. Direct port of workspace-tree-fingerprint.py.
public enum WorkspaceFingerprint {
    public enum Variant: String {
        case monitorApp = "monitor-app"
        case uiTestHost = "ui-test-host"
        /// Variant baked into `run-instruments-audit.sh:776` - includes the audit script
        /// itself and `Sources/HarnessMonitorUITestHost`. Used as the audit run's "did
        /// anything change since the build" canary.
        case audit

        var includes: [String] {
            switch self {
            case .monitorApp:
                return [
                    "HarnessMonitor.entitlements",
                    "HarnessMonitorDaemon.entitlements",
                    "HarnessMonitor.xcodeproj/project.pbxproj",
                    "Resources",
                    "Scripts/bundle-daemon-agent.sh",
                    "Scripts/run-xcode-build-server.sh",
                    "Sources/HarnessMonitor",
                    "Sources/HarnessMonitorKit",
                    "Sources/HarnessMonitorUIPreviewable",
                ]
            case .uiTestHost:
                return [
                    "HarnessMonitor.entitlements",
                    "HarnessMonitorUITestHost.entitlements",
                    "HarnessMonitorDaemon.entitlements",
                    "HarnessMonitor.xcodeproj/project.pbxproj",
                    "Resources",
                    "Scripts/bundle-daemon-agent.sh",
                    "Scripts/run-xcode-build-server.sh",
                    "Sources/HarnessMonitor",
                    "Sources/HarnessMonitorKit",
                    "Sources/HarnessMonitorUIPreviewable",
                ]
            case .audit:
                return [
                    "HarnessMonitor.entitlements",
                    "HarnessMonitorUITestHost.entitlements",
                    "HarnessMonitorDaemon.entitlements",
                    "HarnessMonitor.xcodeproj/project.pbxproj",
                    "Resources",
                    "Scripts/bundle-daemon-agent.sh",
                    "Scripts/run-instruments-audit.sh",
                    "Sources/HarnessMonitor",
                    "Sources/HarnessMonitorKit",
                    "Sources/HarnessMonitorUIPreviewable",
                    "Sources/HarnessMonitorUITestHost",
                ]
            }
        }
    }

    /// Hashes a single directory tree using the same `{relative}\\0{bytes}\\0` framing the
    /// workspace fingerprint uses. Mirrors `bundle_sha256` in run-instruments-audit.sh:752.
    public static func directorySHA256(_ root: URL) throws -> String {
        var hasher = SHA256()
        let files = try collectFiles(under: root)
        for file in files {
            let relativePath = relativeFilePath(from: root, to: file)
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            for chunk in try chunkedRead(file) { hasher.update(data: chunk) }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Returns hex SHA-256 over `<rel>\0<file-bytes>\0...` for every file under each include
    /// path, in sorted relative-path order. Identical scheme to the python script so the
    /// resulting digest matches byte-for-byte.
    public static func compute(variant: Variant, projectDir: URL) throws -> String {
        var hasher = SHA256()
        let fm = FileManager.default

        for relative in variant.includes {
            let target = projectDir.appendingPathComponent(relative)
            guard fm.fileExists(atPath: target.path) else { continue }

            let files = try collectFiles(under: target)
            for file in files {
                let relativePath = relativeFilePath(from: projectDir, to: file)
                hasher.update(data: Data(relativePath.utf8))
                hasher.update(data: Data([0]))
                let stream = try chunkedRead(file)
                for chunk in stream { hasher.update(data: chunk) }
                hasher.update(data: Data([0]))
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func collectFiles(under url: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return [url] }

        var files: [URL] = []
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let candidate as URL in enumerator {
            let attrs = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
            if attrs?.isRegularFile == true { files.append(candidate) }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativeFilePath(from base: URL, to file: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath.hasPrefix(basePath + "/") {
            return String(filePath.dropFirst(basePath.count + 1))
        }
        return filePath
    }

    private static func chunkedRead(_ url: URL) throws -> AnyIterator<Data> {
        let handle = try FileHandle(forReadingFrom: url)
        return AnyIterator {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty {
                try? handle.close()
                return nil
            }
            return chunk
        }
    }
}
