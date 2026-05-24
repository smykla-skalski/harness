import Foundation

public struct DaemonDataHomeProbe: Codable, Equatable, Sendable {
    public var dataHome: String
    public var exists: Bool
    public var regularFileCount: Int
    public var totalBytes: Int64
    public var containsDaemonManifest: Bool
    public var containsSQLiteDatabase: Bool
    public var containsSQLiteWAL: Bool
    public var containsSQLiteSHM: Bool

    enum CodingKeys: String, CodingKey {
        case dataHome = "data_home"
        case exists
        case regularFileCount = "regular_file_count"
        case totalBytes = "total_bytes"
        case containsDaemonManifest = "contains_daemon_manifest"
        case containsSQLiteDatabase = "contains_sqlite_database"
        case containsSQLiteWAL = "contains_sqlite_wal"
        case containsSQLiteSHM = "contains_sqlite_shm"
    }

    public static func unknown(dataHome: String) -> Self {
        Self(
            dataHome: dataHome,
            exists: false,
            regularFileCount: 0,
            totalBytes: 0,
            containsDaemonManifest: false,
            containsSQLiteDatabase: false,
            containsSQLiteWAL: false,
            containsSQLiteSHM: false
        )
    }

    public static func capture(dataHome: URL, fileManager: FileManager = .default) -> Self {
        let dataHomePath = dataHome.path
        guard fileManager.fileExists(atPath: dataHomePath) else {
            return .unknown(dataHome: dataHomePath)
        }

        var regularFileCount = 0
        var totalBytes: Int64 = 0
        var containsDaemonManifest = false
        var containsSQLiteDatabase = false
        var containsSQLiteWAL = false
        var containsSQLiteSHM = false

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: dataHome,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return Self(
                dataHome: dataHomePath,
                exists: true,
                regularFileCount: 0,
                totalBytes: 0,
                containsDaemonManifest: false,
                containsSQLiteDatabase: false,
                containsSQLiteWAL: false,
                containsSQLiteSHM: false
            )
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile == true else { continue }
            regularFileCount += 1
            totalBytes += Int64(values?.fileSize ?? 0)

            switch url.lastPathComponent {
            case "manifest.json":
                if url.path.contains("/harness/daemon/") {
                    containsDaemonManifest = true
                }
            case "harness.db":
                containsSQLiteDatabase = true
            case "harness.db-wal":
                containsSQLiteWAL = true
            case "harness.db-shm":
                containsSQLiteSHM = true
            default:
                break
            }
        }

        return Self(
            dataHome: dataHomePath,
            exists: true,
            regularFileCount: regularFileCount,
            totalBytes: totalBytes,
            containsDaemonManifest: containsDaemonManifest,
            containsSQLiteDatabase: containsSQLiteDatabase,
            containsSQLiteWAL: containsSQLiteWAL,
            containsSQLiteSHM: containsSQLiteSHM
        )
    }
}
