import Foundation
import XCTest

@testable import HarnessMonitorE2ECore

final class LoggedProcessRunnerTests: XCTestCase {
  func testReturnsWhenRootProcessExitsEvenIfBackgroundChildKeepsPipeOpen() throws {
    let logURL = temporaryLogURL()
    let runner = LoggedProcessRunner(environment: [:])
    let startedAt = Date()

    let result = try runner.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "sleep 2 & echo done"],
      logURL: logURL
    )

    XCTAssertEqual(result.exitStatus, 0)
    XCTAssertNil(result.terminationReason)
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0)
    XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains("done"))
  }

  func testTerminatesRunningProcessWhenMonitorTrips() throws {
    let logURL = temporaryLogURL()
    let runner = LoggedProcessRunner(environment: [:], pollInterval: 0.05)
    let startedAt = Date()

    let result = try runner.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "sleep 10"],
      logURL: logURL,
      terminationTrigger: { "test-trigger" }
    )

    XCTAssertNotEqual(result.exitStatus, 0)
    XCTAssertEqual(result.terminationReason, "test-trigger")
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.0)
  }

  private func temporaryLogURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("log")
  }
}
