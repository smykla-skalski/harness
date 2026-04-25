import Foundation
import HarnessMonitorE2ECore
import XCTest

/// Integration smoke tests for the `harness-monitor-e2e recording-triage`
/// subcommand surface. Each test shells into the package-built binary to
/// exercise ArgumentParser wiring + JSON emission in one shot. Tests skip if
/// the binary has not been built yet (e.g. invoked outside a `swift test`).
final class RecordingTriageCommandTests: XCTestCase {
    func testFrameGapsEmitsStructuredJson() throws {
        let binary = try resolveBinary()
        let probeOutput = """
        frame|pkt_pts_time=0.000000
        frame|pkt_pts_time=0.041667
        frame|pkt_pts_time=2.500000
        """
        let work = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let probePath = work.appendingPathComponent("probe.txt")
        try probeOutput.write(to: probePath, atomically: true, encoding: .utf8)

        let result = try run(binary, arguments: [
            "recording-triage", "frame-gaps",
            "--ffprobe-output", probePath.path,
        ])
        XCTAssertEqual(result.status, 0, result.stderr)
        let report = try JSONDecoder().decode(
            RecordingTriage.FrameGapReport.self,
            from: Data(result.stdout.utf8)
        )
        XCTAssertEqual(report.totalFrames, 3)
        XCTAssertEqual(report.freezes.count, 1)
    }

    func testDeadHeadTailEmitsJson() throws {
        let binary = try resolveBinary()
        let result = try run(binary, arguments: [
            "recording-triage", "dead-head-tail",
            "--recording-start", "100",
            "--recording-end", "200",
            "--app-launch", "110",
            "--app-terminate", "198",
        ])
        XCTAssertEqual(result.status, 0, result.stderr)
        let report = try JSONDecoder().decode(
            RecordingTriage.DeadHeadTailReport.self,
            from: Data(result.stdout.utf8)
        )
        XCTAssertTrue(report.isLeadingDead)
        XCTAssertFalse(report.isTrailingDead)
    }

    func testBlackFramesRequiresPaths() throws {
        let binary = try resolveBinary()
        let result = try run(binary, arguments: [
            "recording-triage", "black-frames",
        ])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.stderr.contains("at least one frame path"),
            "stderr=\(result.stderr)"
        )
    }

    private func resolveBinary() throws -> URL {
        let candidate = packageRoot()
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("harness-monitor-e2e")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw XCTSkip("harness-monitor-e2e binary missing at \(candidate.path); run `swift build` first")
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HarnessMonitorE2ECoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // HarnessMonitorE2E
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recording-triage-cli-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ binary: URL, arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
