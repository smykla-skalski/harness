import XCTest
@testable import HarnessMonitorE2ECore

final class SwarmSeedStateTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("swarm-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSeedCreatesHarnessSyncAndLedgerDirectories() throws {
        let dataHome = tempDir.appendingPathComponent("data-home", isDirectory: true)

        let result = try SwarmSeedState.seed(dataHome: dataHome)

        XCTAssertEqual(result.dataHome, dataHome.path)
        XCTAssertTrue(result.seeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataHome.appendingPathComponent("harness").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataHome.appendingPathComponent("e2e-sync").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataHome.appendingPathComponent("e2e-ledger").path))
    }

    func testSeedWritesStallLedgerMarkerWhenAgentAndDurationProvided() throws {
        let dataHome = tempDir.appendingPathComponent("data-home", isDirectory: true)

        _ = try SwarmSeedState.seed(
            dataHome: dataHome,
            stalledAgentID: "agent-1",
            stallSeconds: 7
        )

        let marker = dataHome.appendingPathComponent("e2e-ledger/stall-agent-1.env")
        let body = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertEqual(body, "agent_id=agent-1\nstall_seconds=7\n")
    }
}
