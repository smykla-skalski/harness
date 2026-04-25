import Foundation
import XCTest

/// Resolves and lazily builds the deterministic .mov fixtures used by
/// RecordingTriage tests. The fixtures live outside the SwiftPM package
/// resources because they are regenerable via ffmpeg; committing them
/// would inflate git history while adding no test value.
enum RecordingFixture {
    enum FixtureError: Error, CustomStringConvertible {
        case ffmpegMissing
        case buildScriptMissing(URL)
        case buildFailed(status: Int32, stderr: String)
        case fixtureMissingAfterBuild(URL)

        var description: String {
            switch self {
            case .ffmpegMissing:
                return "ffmpeg/ffprobe not on PATH; install with `brew install ffmpeg`"
            case .buildScriptMissing(let url):
                return "build-fixture.sh not found at \(url.path)"
            case .buildFailed(let status, let stderr):
                return "build-fixture.sh exited with status \(status):\n\(stderr)"
            case .fixtureMissingAfterBuild(let url):
                return "fixture missing after build: \(url.path)"
            }
        }
    }

    static let tinyName = "tiny.mov"
    static let transitionName = "transition.mov"
    static let freezeName = "freeze.mov"

    static func tinyURL() throws -> URL { try url(named: tinyName) }
    static func transitionURL() throws -> URL { try url(named: transitionName) }
    static func freezeURL() throws -> URL { try url(named: freezeName) }

    static func ensureBuilt() throws {
        _ = try tinyURL()
        _ = try transitionURL()
        _ = try freezeURL()
    }

    private static func url(named name: String) throws -> URL {
        let directory = fixturesDirectory()
        let candidate = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        try build(into: directory)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw FixtureError.fixtureMissingAfterBuild(candidate)
        }
        return candidate
    }

    private static func fixturesDirectory() -> URL {
        // Tests/HarnessMonitorE2ECoreTests/RecordingFixture.swift -> .../Tests/Fixtures
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private static func build(into directory: URL) throws {
        guard which("ffmpeg") != nil, which("ffprobe") != nil else {
            throw FixtureError.ffmpegMissing
        }
        let script = repoRoot()
            .appendingPathComponent("scripts/e2e/recording-triage/build-fixture.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw FixtureError.buildScriptMissing(script)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = script
        process.arguments = [directory.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let payload = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: payload, encoding: .utf8) ?? "<binary>"
            throw FixtureError.buildFailed(status: process.terminationStatus, stderr: message)
        }
    }

    private static func repoRoot() -> URL {
        // RecordingFixture.swift -> Tests/HarnessMonitorE2ECoreTests -> Tests -> HarnessMonitorE2E -> Tools -> harness-monitor-macos -> apps -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HarnessMonitorE2ECoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // HarnessMonitorE2E
            .deletingLastPathComponent() // Tools
            .deletingLastPathComponent() // harness-monitor-macos
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repo root
    }

    private static func which(_ binary: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", binary]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: text)
    }
}

/// Smoke test: the helper resolves and builds the fixtures end to end.
/// Real detector tests live in RecordingTriageTests (chunk 2).
final class RecordingFixtureTests: XCTestCase {
    func testFixturesBuildAndAreNonEmpty() throws {
        do {
            try RecordingFixture.ensureBuilt()
        } catch RecordingFixture.FixtureError.ffmpegMissing {
            throw XCTSkip("ffmpeg/ffprobe required for RecordingFixtureTests")
        }

        let tiny = try RecordingFixture.tinyURL()
        let transition = try RecordingFixture.transitionURL()
        let freeze = try RecordingFixture.freezeURL()
        for url in [tiny, transition, freeze] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attributes[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 0, "fixture is empty: \(url.path)")
            XCTAssertLessThan(size, 204_800, "fixture too large (>200 KB): \(url.path)")
        }
    }
}
