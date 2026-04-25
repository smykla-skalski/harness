import XCTest
@testable import HarnessMonitorE2ECore

final class ObservabilityConfigTests: XCTestCase {
    func testWritesExpectedFixture() throws {
        let dataHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("obs-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataHome) }

        try ObservabilityConfig.seed(dataHome: dataHome)

        let configPath = dataHome.appendingPathComponent("harness/observability/config.json")
        let body = try String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(body.contains("\"enabled\": true"))
        XCTAssertTrue(body.contains("\"grpc_endpoint\": \"http://127.0.0.1:4317\""))
        XCTAssertTrue(body.contains("\"monitor_smoke_enabled\": false"))
    }
}
