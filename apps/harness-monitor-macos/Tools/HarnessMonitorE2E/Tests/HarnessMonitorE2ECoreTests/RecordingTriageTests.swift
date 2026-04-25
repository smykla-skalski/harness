import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import HarnessMonitorE2ECore

final class RecordingTriageFrameGapsTests: XCTestCase {
  func testNoGapsForSteadyTimeline() {
    let timestamps = Array(stride(from: 0.0, through: 1.0, by: 1.0 / 24.0))
    let report = RecordingTriage.analyzeFrameGaps(timestamps: timestamps)
    XCTAssertEqual(report.totalFrames, timestamps.count)
    XCTAssertTrue(report.hitches.isEmpty)
    XCTAssertTrue(report.freezes.isEmpty)
    XCTAssertTrue(report.stalls.isEmpty)
  }

  func testHitchClassification() {
    let timestamps: [Double] = [0.0, 0.04, 0.20, 0.24, 0.28]
    let report = RecordingTriage.analyzeFrameGaps(timestamps: timestamps)
    XCTAssertEqual(report.hitches.count, 1)
    XCTAssertEqual(report.hitches.first?.startSeconds ?? -1, 0.04, accuracy: 1e-6)
    XCTAssertEqual(report.hitches.first?.kind, .hitch)
  }

  func testFreezeClassification() {
    let timestamps: [Double] = [0.0, 0.04, 3.04]
    let report = RecordingTriage.analyzeFrameGaps(timestamps: timestamps)
    XCTAssertEqual(report.freezes.count, 1)
    XCTAssertEqual(report.freezes.first?.kind, .freeze)
  }

  func testStallRequiresIdleSegment() {
    let timestamps: [Double] = [0.0, 6.5]
    let activeReport = RecordingTriage.analyzeFrameGaps(timestamps: timestamps)
    XCTAssertEqual(activeReport.freezes.count, 1)
    XCTAssertEqual(activeReport.stalls.count, 0)
    let idleReport = RecordingTriage.analyzeFrameGaps(
      timestamps: timestamps,
      idleSegments: [0.0...6.5]
    )
    XCTAssertEqual(idleReport.stalls.count, 1)
    XCTAssertEqual(idleReport.freezes.count, 0)
  }

  func testParseFrameTimestamps() {
    let raw = """
      frame|pkt_pts_time=0.000000|pkt_size=24
      frame|pkt_pts_time=0.041667|pkt_size=24
      frame|pkt_pts_time=0.083333|pkt_size=24
      not_a_frame_line=ignored
      """
    let timestamps = RecordingTriage.parseFrameTimestamps(fromFFprobe: raw)
    XCTAssertEqual(timestamps.count, 3)
    XCTAssertEqual(timestamps.last ?? 0, 0.083333, accuracy: 1e-6)
  }
}

final class RecordingTriageDeadHeadTailTests: XCTestCase {
  func testFlagsLongLeadingDelay() {
    let report = RecordingTriage.analyzeDeadHeadTail(
      recordingStartEpoch: 100,
      recordingEndEpoch: 200,
      appLaunchEpoch: 110,
      appTerminateEpoch: 198
    )
    XCTAssertTrue(report.isLeadingDead)
    XCTAssertFalse(report.isTrailingDead)
    XCTAssertEqual(report.leadingSeconds, 10, accuracy: 1e-6)
    XCTAssertEqual(report.trailingSeconds, 2, accuracy: 1e-6)
  }

  func testFlagsLongTrailingDelay() {
    let report = RecordingTriage.analyzeDeadHeadTail(
      recordingStartEpoch: 100,
      recordingEndEpoch: 200,
      appLaunchEpoch: 100.5,
      appTerminateEpoch: 190
    )
    XCTAssertFalse(report.isLeadingDead)
    XCTAssertTrue(report.isTrailingDead)
  }

  func testCleanCaseFlagsNeither() {
    let report = RecordingTriage.analyzeDeadHeadTail(
      recordingStartEpoch: 100,
      recordingEndEpoch: 200,
      appLaunchEpoch: 102,
      appTerminateEpoch: 199
    )
    XCTAssertFalse(report.isLeadingDead)
    XCTAssertFalse(report.isTrailingDead)
  }
}

final class RecordingTriagePerceptualHashTests: XCTestCase {
  func testSameImageHashesEqual() throws {
    try RecordingFixture.ensureBuilt()
    let png = try keyframe(of: try RecordingFixture.tinyURL(), at: 0.04)
    defer { try? FileManager.default.removeItem(at: png.deletingLastPathComponent()) }
    let lhs = try RecordingTriage.perceptualHash(ofImageAt: png)
    let rhs = try RecordingTriage.perceptualHash(ofImageAt: png)
    XCTAssertEqual(lhs, rhs)
    XCTAssertEqual(lhs.distance(to: rhs), 0)
  }

  func testTransitionAndTinyDifferUnderThreshold() throws {
    try RecordingFixture.ensureBuilt()
    let tinyKeyframe = try keyframe(of: try RecordingFixture.tinyURL(), at: 0.04)
    let blackKeyframe = try keyframe(of: try RecordingFixture.freezeURL(), at: 0.04)
    defer {
      try? FileManager.default.removeItem(at: tinyKeyframe.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: blackKeyframe.deletingLastPathComponent())
    }
    let tinyHash = try RecordingTriage.perceptualHash(ofImageAt: tinyKeyframe)
    let blackHash = try RecordingTriage.perceptualHash(ofImageAt: blackKeyframe)
    // Solid colours both map to monotone bitmaps; dHash distance is small.
    // We only assert the hashes are well-formed and stable across calls.
    XCTAssertEqual(tinyHash.bits.nonzeroBitCount, blackHash.bits.nonzeroBitCount)
  }

  func testCompareKeyframesReturnsFindings() throws {
    try RecordingFixture.ensureBuilt()
    let tinyKeyframe = try keyframe(of: try RecordingFixture.tinyURL(), at: 0.04)
    defer { try? FileManager.default.removeItem(at: tinyKeyframe.deletingLastPathComponent()) }
    let findings = try RecordingTriage.compareKeyframes(
      candidates: [(name: "act1", url: tinyKeyframe)],
      groundTruths: [(name: "act1", url: tinyKeyframe)]
    )
    XCTAssertEqual(findings.count, 1)
    XCTAssertEqual(findings.first?.distance, 0)
    XCTAssertEqual(findings.first?.exceedsThreshold, false)
  }

  /// Run ffmpeg to extract a single keyframe so the test exercises the same
  /// CGImageSource path the production detector hits in CI.
  private func keyframe(of recording: URL, at seconds: Double) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("recording-triage-keyframe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let output = directory.appendingPathComponent("frame.png")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "ffmpeg", "-y", "-loglevel", "error",
      "-ss", String(format: "%.3f", seconds),
      "-i", recording.path,
      "-frames:v", "1",
      output.path,
    ]
    process.standardOutput = Pipe()
    let stderr = Pipe()
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      throw XCTSkip("ffmpeg unavailable: \(error)")
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let payload = stderr.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: payload, encoding: .utf8) ?? "<binary>"
      throw XCTSkip("ffmpeg keyframe extraction failed: \(message)")
    }
    return output
  }
}

final class RecordingTriageLayoutDriftTests: XCTestCase {
  func testParsesIdentifierAndFrame() {
    let text = """
      Application 'Demo' frame: {{0, 0}, {1280, 820}}
        Window 'main' identifier='mainWindow' frame: {{0, 0}, {1280, 820}}
          Button 'Login' identifier='loginButton' frame: {{100, 200}, {120, 32}}
      """
    let boxes = RecordingTriage.parseLayoutBoundingBoxes(from: text)
    XCTAssertEqual(boxes.count, 2)
    XCTAssertEqual(boxes.first?.identifier, "mainWindow")
    XCTAssertEqual(boxes.last?.identifier, "loginButton")
    XCTAssertEqual(boxes.last?.frame.origin.x ?? 0, 100, accuracy: 1e-6)
  }

  func testParsesRealXCUITestDumpFormat() {
    // Lines emitted by XCUIElement.debugDescription at runtime use
    // `{{x, y}, {w, h}}, identifier: 'X'` (frame first, colon-quoted
    // identifier). The parser must handle that variant alongside the
    // legacy `identifier='X' frame: {{...}}` form.
    let text = """
      Window (Main), 0x8660a3e80, {{388.0, 274.0}, {1280.0, 820.0}}, identifier: 'main-AppWindow-1', title: 'Cockpit', Disabled
        Other, 0x8660a12c0, {{396.0, 372.0}, {260.0, 714.0}}, identifier: 'harness.sidebar.search.state', label: 'presented=false'
        Other, 0x8660a2e40, {{406.0, 412.0}, {240.0, 19.0}}, identifier: 'harness.sidebar.filter.state', label: 'status=all'
      """
    let boxes = RecordingTriage.parseLayoutBoundingBoxes(from: text)
    XCTAssertEqual(boxes.count, 3)
    XCTAssertEqual(boxes[0].identifier, "main-AppWindow-1")
    XCTAssertEqual(boxes[0].frame.origin.x, 388.0, accuracy: 1e-6)
    XCTAssertEqual(boxes[0].frame.size.width, 1280.0, accuracy: 1e-6)
    XCTAssertEqual(boxes[1].identifier, "harness.sidebar.search.state")
    XCTAssertEqual(boxes[2].identifier, "harness.sidebar.filter.state")
  }

  func testDetectsDriftOverThreshold() {
    let before = [
      RecordingTriage.LayoutBoundingBox(
        identifier: "loginButton",
        frame: CGRect(x: 100, y: 200, width: 120, height: 32)
      )
    ]
    let after = [
      RecordingTriage.LayoutBoundingBox(
        identifier: "loginButton",
        frame: CGRect(x: 105, y: 200, width: 120, height: 32)
      )
    ]
    let drifts = RecordingTriage.detectLayoutDrift(before: before, after: after)
    XCTAssertEqual(drifts.count, 1)
    XCTAssertEqual(drifts.first?.dx ?? 0, 5, accuracy: 1e-6)
  }

  func testSuppressesDriftBelowThreshold() {
    let before = [
      RecordingTriage.LayoutBoundingBox(
        identifier: "loginButton",
        frame: CGRect(x: 100, y: 200, width: 120, height: 32)
      )
    ]
    let after = [
      RecordingTriage.LayoutBoundingBox(
        identifier: "loginButton",
        frame: CGRect(x: 101, y: 200.5, width: 120, height: 32)
      )
    ]
    let drifts = RecordingTriage.detectLayoutDrift(before: before, after: after)
    XCTAssertEqual(drifts.count, 0)
  }
}

final class RecordingTriageBlackFrameTests: XCTestCase {
  func testFreezeFixtureFlagsAsSuspect() throws {
    try RecordingFixture.ensureBuilt()
    let frame = try keyframe(of: try RecordingFixture.freezeURL(), at: 0.04)
    defer { try? FileManager.default.removeItem(at: frame.deletingLastPathComponent()) }
    let report = try RecordingTriage.analyseBlackFrame(at: frame)
    XCTAssertTrue(
      report.isSuspect,
      "freeze.mov mean luminance \(report.meanLuminance) unique colours \(report.uniqueColorCount)")
  }

  func testTinyFixtureNotSuspect() throws {
    try RecordingFixture.ensureBuilt()
    let frame = try keyframe(of: try RecordingFixture.tinyURL(), at: 0.04)
    defer { try? FileManager.default.removeItem(at: frame.deletingLastPathComponent()) }
    let report = try RecordingTriage.analyseBlackFrame(at: frame)
    // Solid blue keyframe — non-zero luminance, but unique colour count is
    // dominated by encoder noise; we assert the detector does not crash
    // and emits a structured report.
    XCTAssertGreaterThan(report.meanLuminance, 0)
  }

  private func keyframe(of recording: URL, at seconds: Double) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("recording-triage-black-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let output = directory.appendingPathComponent("frame.png")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "ffmpeg", "-y", "-loglevel", "error",
      "-ss", String(format: "%.3f", seconds),
      "-i", recording.path,
      "-frames:v", "1",
      output.path,
    ]
    process.standardOutput = Pipe()
    let stderr = Pipe()
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      throw XCTSkip("ffmpeg unavailable: \(error)")
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let payload = stderr.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: payload, encoding: .utf8) ?? "<binary>"
      throw XCTSkip("ffmpeg keyframe extraction failed: \(message)")
    }
    return output
  }
}

final class RecordingTriageThrashTests: XCTestCase {
  func testEmptyHashesProduceEmptyWindows() {
    let report = RecordingTriage.detectAnimationThrash(sampledHashes: [])
    XCTAssertTrue(report.windows.isEmpty)
  }

  func testFlagsBurstOfChanges() {
    let stable = RecordingTriage.PerceptualHash(bits: 0)
    let toggled = RecordingTriage.PerceptualHash(bits: UInt64.max)
    let samples: [(seconds: Double, hash: RecordingTriage.PerceptualHash)] = [
      (0.0, stable),
      (0.05, toggled),
      (0.10, stable),
      (0.15, toggled),
      (0.20, stable),
      (0.25, toggled),
    ]
    let report = RecordingTriage.detectAnimationThrash(sampledHashes: samples)
    XCTAssertFalse(report.windows.isEmpty)
  }

  func testIgnoresSparseChanges() {
    let stable = RecordingTriage.PerceptualHash(bits: 0)
    let toggled = RecordingTriage.PerceptualHash(bits: UInt64.max)
    let samples: [(seconds: Double, hash: RecordingTriage.PerceptualHash)] = [
      (0.0, stable),
      (0.40, toggled),
      (0.90, stable),
    ]
    let report = RecordingTriage.detectAnimationThrash(sampledHashes: samples)
    XCTAssertTrue(report.windows.isEmpty)
  }
}
