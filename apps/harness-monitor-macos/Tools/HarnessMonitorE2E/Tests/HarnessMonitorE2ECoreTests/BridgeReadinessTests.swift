import XCTest
@testable import HarnessMonitorE2ECore

final class BridgeReadinessTests: XCTestCase {
    func testReadyWhenAllCapabilitiesHealthy() {
        let json = """
        { "running": true, "capabilities": {
            "codex": { "healthy": true },
            "agent-tui": { "healthy": true }
        } }
        """
        XCTAssertTrue(BridgeReadiness.isReady(fromJSON: Data(json.utf8)))
    }

    func testNotReadyWhenAnyCapabilityUnhealthy() {
        let json = """
        { "running": true, "capabilities": {
            "codex": { "healthy": true },
            "agent-tui": { "healthy": false }
        } }
        """
        XCTAssertFalse(BridgeReadiness.isReady(fromJSON: Data(json.utf8)))
    }

    func testNotReadyWhenNotRunning() {
        XCTAssertFalse(BridgeReadiness.isReady(fromJSON: Data(#"{ "running": false }"#.utf8)))
    }

    func testNotReadyWhenCapabilityMissing() {
        let json = """
        { "running": true, "capabilities": { "codex": { "healthy": true } } }
        """
        XCTAssertFalse(BridgeReadiness.isReady(fromJSON: Data(json.utf8)))
    }

    func testNotReadyOnMalformedJSON() {
        XCTAssertFalse(BridgeReadiness.isReady(fromJSON: Data("garbage".utf8)))
    }
}
