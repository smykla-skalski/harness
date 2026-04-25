import Foundation
@testable import HarnessMonitorE2ECore
import XCTest

/// Coverage for `RecordingTriage.analyzeActTiming(markers:recordingStart:appLaunch:)`.
/// The analyzer turns marker mtimes into recording-relative offsets so the
/// checklist emitter can drive `lifecycle.ttff`, `lifecycle.dashboard`, and the
/// suite-speed handoff verdicts without re-reading the filesystem.
final class ActTimingTests: XCTestCase {
    func testProducesPerActWindowAndHandoffGap() {
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let appLaunch = Date(timeIntervalSince1970: 1_699_999_999)
        let markers: [RecordingTriage.ActMarker] = [
            .init(act: "act1", kind: .ready, payload: [:], mtime: recordingStart.addingTimeInterval(0.5)),
            .init(act: "act1", kind: .ack, payload: [:], mtime: recordingStart.addingTimeInterval(1.5)),
            .init(act: "act2", kind: .ready, payload: [:], mtime: recordingStart.addingTimeInterval(3.0)),
            .init(act: "act2", kind: .ack, payload: [:], mtime: recordingStart.addingTimeInterval(4.0)),
        ]

        let report = RecordingTriage.analyzeActTiming(
            markers: markers,
            recordingStart: recordingStart,
            appLaunch: appLaunch
        )

        XCTAssertEqual(report.ttffSeconds, 1.0, accuracy: 1e-6)
        XCTAssertEqual(report.dashboardLatencySeconds ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(report.acts.count, 2)

        let act1 = report.acts[0]
        XCTAssertEqual(act1.act, "act1")
        XCTAssertEqual(act1.readySeconds ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(act1.ackSeconds ?? -1, 1.5, accuracy: 1e-6)
        XCTAssertEqual(act1.durationSeconds ?? -1, 1.0, accuracy: 1e-6)
        XCTAssertEqual(act1.gapToNextSeconds ?? -1, 1.5, accuracy: 1e-6)

        let act2 = report.acts[1]
        XCTAssertEqual(act2.gapToNextSeconds, nil, "last act has no successor gap")
    }

    func testMissingAckYieldsNilEnd() {
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let markers: [RecordingTriage.ActMarker] = [
            .init(act: "act1", kind: .ready, payload: [:], mtime: recordingStart.addingTimeInterval(0.5)),
        ]
        let report = RecordingTriage.analyzeActTiming(
            markers: markers,
            recordingStart: recordingStart,
            appLaunch: recordingStart
        )
        XCTAssertEqual(report.acts.count, 1)
        XCTAssertEqual(report.acts[0].ackSeconds, nil)
        XCTAssertEqual(report.acts[0].durationSeconds, nil)
    }

    func testNegativeTtffClampsToZeroWhenRecordingStartedFirst() {
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let appLaunch = recordingStart.addingTimeInterval(0.4)
        let report = RecordingTriage.analyzeActTiming(
            markers: [],
            recordingStart: recordingStart,
            appLaunch: appLaunch
        )
        XCTAssertEqual(report.ttffSeconds, 0.0, accuracy: 1e-6)
    }

    func testActsAreSortedByReadyTime() {
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let markers: [RecordingTriage.ActMarker] = [
            .init(act: "act3", kind: .ready, payload: [:], mtime: recordingStart.addingTimeInterval(5.0)),
            .init(act: "act1", kind: .ready, payload: [:], mtime: recordingStart.addingTimeInterval(0.5)),
            .init(act: "act2", kind: .ready, payload: [:], mtime: recordingStart.addingTimeInterval(2.0)),
        ]
        let report = RecordingTriage.analyzeActTiming(
            markers: markers,
            recordingStart: recordingStart,
            appLaunch: recordingStart
        )
        XCTAssertEqual(report.acts.map { $0.act }, ["act1", "act2", "act3"])
    }
}
