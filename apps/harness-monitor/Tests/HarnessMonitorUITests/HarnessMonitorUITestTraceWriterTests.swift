import Foundation
import XCTest

final class HarnessMonitorUITestTraceWriterTests: XCTestCase {
  func testTraceWriterAppendsJsonlRecordsInOrder() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessMonitorUITestTraceWriterTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = HarnessMonitorUITestTraceWriter(
      fileURL: root.appendingPathComponent("ui-trace.jsonl")
    )
    writer.append(
      component: "swarm",
      event: "launch.start",
      testName: "HarnessMonitorAgentsE2ETests.testSwarmFullFlow",
      details: [
        "session_id": "sess-1234",
        "mode": "live",
      ]
    )
    writer.append(
      component: "swarm",
      event: "open-session.failed",
      testName: "HarnessMonitorAgentsE2ETests.testSwarmFullFlow",
      details: [
        "session_id": "sess-1234",
        "identifier": "harness.sidebar.session.sess-1234",
      ]
    )

    let traceURL = root.appendingPathComponent("ui-trace.jsonl")
    let contents = try String(contentsOf: traceURL, encoding: .utf8)
    let lines = contents.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 2)

    let decoder = JSONDecoder()
    let first = try decoder.decode(
      HarnessMonitorUITestTraceEvent.self,
      from: Data(lines[0].utf8)
    )
    let second = try decoder.decode(
      HarnessMonitorUITestTraceEvent.self,
      from: Data(lines[1].utf8)
    )

    XCTAssertEqual(first.component, "swarm")
    XCTAssertEqual(first.event, "launch.start")
    XCTAssertEqual(first.testName, "HarnessMonitorAgentsE2ETests.testSwarmFullFlow")
    XCTAssertEqual(first.details["session_id"], "sess-1234")
    XCTAssertEqual(first.details["mode"], "live")

    XCTAssertEqual(second.event, "open-session.failed")
    XCTAssertEqual(second.details["identifier"], "harness.sidebar.session.sess-1234")
  }
}
