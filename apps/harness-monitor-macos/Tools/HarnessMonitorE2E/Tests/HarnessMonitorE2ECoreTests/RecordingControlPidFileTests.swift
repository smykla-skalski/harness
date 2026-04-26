import XCTest

@testable import HarnessMonitorE2ECore

@available(macOS 15.0, *)
final class RecordingControlPidFileTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RecordingControlPidFileTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory = temporaryDirectory {
      try? FileManager.default.removeItem(at: directory)
    }
    try super.tearDownWithError()
  }

  func testWriteCreatesPidFileWithDecimalRepresentation() throws {
    let target = try RecordingControlPidFile.write(pid: 12345, into: temporaryDirectory)
    let raw = try String(contentsOf: target, encoding: .utf8)
    XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), "12345")
    XCTAssertEqual(target.lastPathComponent, "start.pid")
  }

  func testWriteOverwritesExistingPidFile() throws {
    _ = try RecordingControlPidFile.write(pid: 1, into: temporaryDirectory)
    let target = try RecordingControlPidFile.write(pid: 9876, into: temporaryDirectory)
    let raw = try String(contentsOf: target, encoding: .utf8)
    XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), "9876")
  }

  func testReadReturnsParsedPidFromFile() throws {
    _ = try RecordingControlPidFile.write(pid: 4242, into: temporaryDirectory)
    XCTAssertEqual(RecordingControlPidFile.read(from: temporaryDirectory), 4242)
  }

  func testReadIgnoresSurroundingWhitespaceAndNewlines() throws {
    let target = temporaryDirectory.appendingPathComponent("start.pid")
    try Data("  7777\n".utf8).write(to: target, options: .atomic)
    XCTAssertEqual(RecordingControlPidFile.read(from: temporaryDirectory), 7777)
  }

  func testReadReturnsNilWhenFileMissing() {
    XCTAssertNil(RecordingControlPidFile.read(from: temporaryDirectory))
  }

  func testReadReturnsNilWhenContentsAreNotAnInteger() throws {
    let target = temporaryDirectory.appendingPathComponent("start.pid")
    try Data("not-a-pid".utf8).write(to: target, options: .atomic)
    XCTAssertNil(RecordingControlPidFile.read(from: temporaryDirectory))
  }
}
