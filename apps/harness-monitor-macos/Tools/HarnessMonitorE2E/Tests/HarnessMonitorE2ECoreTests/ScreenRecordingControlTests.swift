import Darwin
import XCTest
@testable import HarnessMonitorE2ECore

final class ScreenRecordingControlTests: XCTestCase {
    func testManifestRoundTripPreservesAllFields() throws {
        let manifest = ScreenRecordingManifest(
            processID: 321,
            outputPath: "/tmp/swarm-full-flow.mov",
            logPath: "/tmp/screen-recording.log"
        )

        let payload = try manifest.encoded()
        let decoded = try ScreenRecordingManifest.decode(from: payload)

        XCTAssertEqual(decoded.processID, manifest.processID)
        XCTAssertEqual(decoded.outputPath, manifest.outputPath)
        XCTAssertEqual(decoded.logPath, manifest.logPath)
    }

    func testStopSendsSigintAndReturnsWhenRecorderExitsGracefully() {
        let runtime = FakeScreenRecordingRuntime(
            aliveAnswers: [true, false]
        )
        let manifest = ScreenRecordingManifest(
            processID: 777,
            outputPath: "/tmp/swarm-full-flow.mov",
            logPath: "/tmp/screen-recording.log"
        )

        ScreenRecordingStopper.stop(
            manifest: manifest,
            runtime: runtime,
            gracefulTimeout: 1,
            termTimeout: 1,
            pollInterval: 0.5
        )

        XCTAssertEqual(runtime.sentSignals, [SIGINT])
    }

    func testStopEscalatesWhenRecorderIgnoresGracefulSignals() {
        let runtime = FakeScreenRecordingRuntime(
            aliveAnswers: Array(repeating: true, count: 10)
        )
        let manifest = ScreenRecordingManifest(
            processID: 888,
            outputPath: "/tmp/swarm-full-flow.mov",
            logPath: "/tmp/screen-recording.log"
        )

        ScreenRecordingStopper.stop(
            manifest: manifest,
            runtime: runtime,
            gracefulTimeout: 1,
            termTimeout: 0.5,
            pollInterval: 0.5
        )

        XCTAssertEqual(runtime.sentSignals, [SIGINT, SIGTERM, SIGKILL])
    }
}

private final class FakeScreenRecordingRuntime: ScreenRecordingProcessRuntime {
    private var aliveAnswers: [Bool]
    private var currentTime = Date(timeIntervalSince1970: 0)
    var sentSignals: [Int32] = []

    init(aliveAnswers: [Bool]) {
        self.aliveAnswers = aliveAnswers
    }

    func now() -> Date {
        currentTime
    }

    func sleep(seconds: TimeInterval) {
        currentTime = currentTime.addingTimeInterval(seconds)
    }

    func isAlive(pid _: Int32) -> Bool {
        if aliveAnswers.isEmpty {
            return false
        }
        return aliveAnswers.removeFirst()
    }

    func send(signal: Int32, to _: Int32) {
        sentSignals.append(signal)
    }
}
