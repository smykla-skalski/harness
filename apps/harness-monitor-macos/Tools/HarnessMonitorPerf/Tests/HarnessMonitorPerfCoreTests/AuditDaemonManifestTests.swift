import XCTest
@testable import HarnessMonitorPerfCore

final class AuditDaemonManifestTests: XCTestCase {
    func testMirrorRejectsDeadExternalDaemonManifestPID() throws {
        let paths = try makeExternalDaemonDataHome(pid: 424_242)
        defer { try? FileManager.default.removeItem(at: paths.root) }

        XCTAssertThrowsError(
            try AuditRunner.prepareAuditDaemonDataHomeMirror(
                sourceDataHome: paths.sourceDataHome,
                mirrorDataHome: paths.mirrorDataHome,
                processIsLive: { pid in
                    XCTAssertEqual(pid, 424_242)
                    return false
                }
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("manifest pid 424242 is not live")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.mirrorDataHome.path))
    }

    func testMirrorAllowsLiveExternalDaemonManifestPID() throws {
        let paths = try makeExternalDaemonDataHome(pid: 123)
        defer { try? FileManager.default.removeItem(at: paths.root) }

        try AuditRunner.prepareAuditDaemonDataHomeMirror(
            sourceDataHome: paths.sourceDataHome,
            mirrorDataHome: paths.mirrorDataHome,
            processIsLive: { pid in
                XCTAssertEqual(pid, 123)
                return true
            }
        )

        let mirrorTokenURL = paths.mirrorDataHome
            .appendingPathComponent("harness/daemon/auth-token")
        let mirrorManifestURL = paths.mirrorDataHome
            .appendingPathComponent("harness/daemon/manifest.json")
        let mirrorManifestData = try Data(contentsOf: mirrorManifestURL)
        let mirrorManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mirrorManifestData) as? [String: Any]
        )
        XCTAssertEqual(mirrorManifest["token_path"] as? String, mirrorTokenURL.path)
        XCTAssertEqual(try String(contentsOf: mirrorTokenURL, encoding: .utf8), "secret")
    }

    private struct DataHomePaths {
        var root: URL
        var sourceDataHome: URL
        var mirrorDataHome: URL
    }

    private func makeExternalDaemonDataHome(pid: Int) throws -> DataHomePaths {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("audit-daemon-manifest-\(UUID().uuidString)")
        let sourceDataHome = root.appendingPathComponent("source", isDirectory: true)
        let mirrorDataHome = root.appendingPathComponent("mirror", isDirectory: true)
        let daemonRoot = sourceDataHome.appendingPathComponent("harness/daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonRoot, withIntermediateDirectories: true)
        let tokenURL = daemonRoot.appendingPathComponent("auth-token")
        try Data("secret".utf8).write(to: tokenURL)
        try Data("""
        {
          "endpoint": "http://127.0.0.1:60385",
          "pid": \(pid),
          "started_at": "2026-05-12T15:45:43Z",
          "token_path": "\(tokenURL.path)",
          "version": "34.1.0"
        }
        """.utf8).write(to: daemonRoot.appendingPathComponent("manifest.json"))
        return DataHomePaths(
            root: root,
            sourceDataHome: sourceDataHome,
            mirrorDataHome: mirrorDataHome
        )
    }
}
