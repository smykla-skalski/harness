import Foundation
import XCTest

@testable import HarnessMonitorE2ECore

/// Coverage for `RecordingTriage.parseActMarker(at:)`. The orchestrator writes
/// each `<act>.ready` / `<act>.ack` marker as `key=value` lines (ack files use
/// the literal token `ack`). The parser must:
///   - infer the act name and kind from the filename,
///   - read every key/value pair into a payload dictionary,
///   - return the wall-clock mtime so timing analysis has an anchor,
///   - tolerate the bare `ack\n` body without recording bogus payload entries.
final class ActMarkerParseTests: XCTestCase {
  func testParsesReadyMarkerWithPayload() throws {
    let workDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workDir) }
    let path = workDir.appendingPathComponent("act1.ready")
    let body = """
      act=act1
      leader_id=claude-20260425174718737902000
      session_id=sess-e2e-swarm-abc
      """
    try body.write(to: path, atomically: true, encoding: .utf8)

    let marker = try RecordingTriage.parseActMarker(at: path)
    XCTAssertEqual(marker.act, "act1")
    XCTAssertEqual(marker.kind, .ready)
    XCTAssertEqual(marker.payload["leader_id"], "claude-20260425174718737902000")
    XCTAssertEqual(marker.payload["session_id"], "sess-e2e-swarm-abc")
    let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
    if let modified = attrs[.modificationDate] as? Date {
      XCTAssertEqual(
        marker.mtime.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1.0)
    } else {
      XCTFail("missing modificationDate attribute")
    }
  }

  func testParsesAckMarkerWithLiteralAckBody() throws {
    let workDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workDir) }
    let path = workDir.appendingPathComponent("act4.ack")
    try "ack\n".write(to: path, atomically: true, encoding: .utf8)

    let marker = try RecordingTriage.parseActMarker(at: path)
    XCTAssertEqual(marker.act, "act4")
    XCTAssertEqual(marker.kind, .ack)
    XCTAssertTrue(marker.payload.isEmpty, "ack body should not yield payload entries")
  }

  func testRejectsUnknownSuffix() {
    let workDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workDir) }
    let path = workDir.appendingPathComponent("act1.bogus")
    try? "ack\n".write(to: path, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try RecordingTriage.parseActMarker(at: path))
  }

  func testIgnoresBlankAndCommentLines() throws {
    let workDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workDir) }
    let path = workDir.appendingPathComponent("act2.ready")
    let body = """
      act=act2

      worker_codex_id=codex-1
      # comment line should be ignored
      worker_claude_id=claude-1
      """
    try body.write(to: path, atomically: true, encoding: .utf8)

    let marker = try RecordingTriage.parseActMarker(at: path)
    XCTAssertEqual(marker.payload.count, 2)
    XCTAssertEqual(marker.payload["worker_codex_id"], "codex-1")
    XCTAssertEqual(marker.payload["worker_claude_id"], "claude-1")
  }

  private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("act-marker-parse-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
