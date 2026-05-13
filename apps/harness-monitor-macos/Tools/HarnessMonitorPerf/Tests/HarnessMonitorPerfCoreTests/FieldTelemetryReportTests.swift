import XCTest
@testable import HarnessMonitorPerfCore

final class FieldTelemetryReportTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("field-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testBuildNormalizesAuditVocabulary() throws {
        let report = FieldTelemetryReportWriter.build(inputs: .init(
            label: "release-34.2.0",
            metricKit: .init(
                launchAppInitToReadyMilliseconds: 410,
                animationHitchTimeRatio: 0.02,
                hangCount: 3,
                peakMemoryMegabytes: 512
            ),
            organizer: .init(
                launchAppInitToReadyMilliseconds: 395,
                hitchRate: 0.01,
                hangRate: 0.004,
                memoryPeakMegabytes: 480,
                releaseComparisonNotes: ["search interactions regressed after release 34.2.0"]
            ),
            appStoreConnectPerformanceAPI: .init(
                releaseComparisonNotes: ["release-over-release launch regression on iPhone 15 Pro"]
            )
        ))

        XCTAssertEqual(report.signals.map(\.name), [
            "launch_app_init_to_ready_ms",
            "hitches",
            "potential_hangs",
            "allocation_growth",
            "scenario_specific_regressions",
        ])
        XCTAssertEqual(report.signals[0].observations.map(\.source), ["metric_kit", "organizer"])
        XCTAssertEqual(report.signals[4].observations.count, 2)
    }

    func testWriteProducesJSONAndMarkdown() throws {
        let report = FieldTelemetryReportWriter.build(inputs: .init(
            label: "release-34.2.0",
            metricKit: .init(
                launchAppInitToReadyMilliseconds: 410,
                animationHitchTimeRatio: 0.02,
                hangCount: 3,
                peakMemoryMegabytes: 512
            ),
            organizer: .init(
                launchAppInitToReadyMilliseconds: 395,
                hitchRate: 0.01,
                hangRate: 0.004,
                memoryPeakMegabytes: 480,
                releaseComparisonNotes: ["search interactions regressed after release 34.2.0"]
            ),
            appStoreConnectPerformanceAPI: .init(
                releaseComparisonNotes: ["release-over-release launch regression on iPhone 15 Pro"]
            )
        ))

        try FieldTelemetryReportWriter.write(report: report, to: workDir)

        let jsonURL = workDir.appendingPathComponent("field-telemetry.json")
        let markdownURL = workDir.appendingPathComponent("field-telemetry.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))

        let jsonData = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(FieldTelemetryReportWriter.Report.self, from: jsonData)
        XCTAssertEqual(decoded.signals.count, 5)

        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Field Telemetry Report: release-34.2.0"))
        XCTAssertTrue(markdown.contains("| launch_app_init_to_ready_ms | metric_kit | launch_app_init_to_ready_ms | 410 |  |"))
        XCTAssertTrue(markdown.contains("scenario_specific_regressions"))
        XCTAssertTrue(markdown.contains("release-over-release launch regression on iPhone 15 Pro"))
    }
}
