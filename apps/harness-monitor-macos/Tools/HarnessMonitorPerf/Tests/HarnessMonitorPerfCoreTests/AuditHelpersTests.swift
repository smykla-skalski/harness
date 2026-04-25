import XCTest
@testable import HarnessMonitorPerfCore

final class AuditHelpersTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("perf-helpers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testDirectorySHA256IsStableAndContentSensitive() throws {
        let dir = workDir.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Resources"), withIntermediateDirectories: true
        )
        try Data("a".utf8).write(to: dir.appendingPathComponent("Info.plist"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("Resources/Asset.bin"))
        let first = try WorkspaceFingerprint.directorySHA256(dir)
        let second = try WorkspaceFingerprint.directorySHA256(dir)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)

        try Data("c".utf8).write(to: dir.appendingPathComponent("Info.plist"))
        let mutated = try WorkspaceFingerprint.directorySHA256(dir)
        XCTAssertNotEqual(first, mutated)
    }

    func testAuditWorkspaceVariantIncludesAuditScript() throws {
        let projectDir = workDir.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("Sources/HarnessMonitor"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("Sources/HarnessMonitorUITestHost"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("Scripts"),
            withIntermediateDirectories: true
        )
        try Data("script".utf8).write(
            to: projectDir.appendingPathComponent("Scripts/run-instruments-audit.sh")
        )
        try Data("ui-host".utf8).write(
            to: projectDir.appendingPathComponent("Sources/HarnessMonitorUITestHost/main.swift")
        )

        let hash = try WorkspaceFingerprint.compute(variant: .audit, projectDir: projectDir)
        XCTAssertEqual(hash.count, 64)
    }

    func testTOCLaunchedProcessAndEndReason() throws {
        let xml = """
        <?xml version="1.0"?>
        <trace-toc>
          <run number="1">
            <processes>
              <process pid="0" path="/launchd"/>
              <process pid="42" path="/Apps/Harness Monitor.app/Contents/MacOS/Harness Monitor"/>
            </processes>
            <end-reason>Time limit reached</end-reason>
          </run>
        </trace-toc>
        """
        let toc = try XctraceTOC(data: Data(xml.utf8))
        XCTAssertEqual(toc.launchedProcessPath(), "/Apps/Harness Monitor.app/Contents/MacOS/Harness Monitor")
        XCTAssertEqual(toc.endReason(), "Time limit reached")
    }

    func testTOCMissingFieldsReturnEmpty() throws {
        let xml = """
        <?xml version="1.0"?>
        <trace-toc><run number="1"><processes><process pid="0" path="/launchd"/></processes></run></trace-toc>
        """
        let toc = try XctraceTOC(data: Data(xml.utf8))
        XCTAssertEqual(toc.launchedProcessPath(), "")
        XCTAssertEqual(toc.endReason(), "")
    }
}
