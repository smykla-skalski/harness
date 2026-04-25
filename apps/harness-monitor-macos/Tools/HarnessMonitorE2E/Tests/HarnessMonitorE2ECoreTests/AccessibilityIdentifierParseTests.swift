import CoreGraphics
import Foundation
import XCTest

@testable import HarnessMonitorE2ECore

/// Coverage for `RecordingTriage.parseAccessibilityIdentifiers(from:)`.
/// The parser scans an XCUITest debug-description-style hierarchy dump
/// (`swarm-actN.txt`) and yields one record per line that carries both an
/// `identifier: '...'` clause and a `{{x, y}, {w, h}}` frame, capturing the
/// optional `label: '...'` payload and the `Selected` modifier so downstream
/// surface assertions can drive verdicts without re-parsing the file.
final class AccessibilityIdentifierParseTests: XCTestCase {
  func testParsesIdentifierWithFrameAndLabel() {
    let line =
      "                  Other, 0x8b99c5400, {{680.0, 765.0}, {644.0, 10.0}}, "
      + "identifier: 'harness.session.tasks.state', label: 'taskCount=0, taskIDs='"
    let records = RecordingTriage.parseAccessibilityIdentifiers(from: line)
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].identifier, "harness.session.tasks.state")
    XCTAssertEqual(records[0].label, "taskCount=0, taskIDs=")
    XCTAssertEqual(records[0].frame, CGRect(x: 680.0, y: 765.0, width: 644.0, height: 10.0))
    XCTAssertFalse(records[0].isSelected)
  }

  func testCaptureSelectedModifier() {
    let line =
      "                  Cell, 0x8b99b5040, {{406.0, 471.0}, {240.0, 74.0}}, "
      + "identifier: 'harness.sidebar.session.sess-foo', Keyboard Focused, Selected"
    let records = RecordingTriage.parseAccessibilityIdentifiers(from: line)
    XCTAssertEqual(records.count, 1)
    XCTAssertTrue(records[0].isSelected)
    XCTAssertNil(records[0].label)
  }

  func testSkipsLineWithoutIdentifier() {
    let line =
      "                  Splitter, 0x8b99b7200, {{656.0, 326.0}, {0.0, 768.0}}, value: 268, Disabled"
    let records = RecordingTriage.parseAccessibilityIdentifiers(from: line)
    XCTAssertTrue(records.isEmpty)
  }

  func testSkipsLineWithoutFrame() {
    let line = "Attributes: Application, 0x8b99af340, identifier: 'main-AppWindow-1', Disabled"
    let records = RecordingTriage.parseAccessibilityIdentifiers(from: line)
    XCTAssertTrue(records.isEmpty)
  }

  func testWalksMultiLineHierarchy() {
    let text = """
                Other, 0x1, {{0.0, 0.0}, {10.0, 10.0}}, identifier: 'a.first', label: 'first'
                StaticText, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, label: 'no identifier'
                Other, 0x3, {{20.0, 20.0}, {30.0, 30.0}}, identifier: 'a.second'
      """
    let records = RecordingTriage.parseAccessibilityIdentifiers(from: text)
    XCTAssertEqual(records.map { $0.identifier }, ["a.first", "a.second"])
    XCTAssertEqual(records[0].label, "first")
    XCTAssertNil(records[1].label)
  }

  func testParsesNegativeFrameOrigin() {
    let line = "Other, 0x4, {{-1.5, -2.5}, {3.0, 4.0}}, identifier: 'offscreen.thing'"
    let records = RecordingTriage.parseAccessibilityIdentifiers(from: line)
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].frame.origin.x, -1.5, accuracy: 1e-6)
    XCTAssertEqual(records[0].frame.origin.y, -2.5, accuracy: 1e-6)
  }
}
