import XCTest
@testable import HarnessMonitorPerfCore

final class PreviewLatencyMeasurerTests: XCTestCase {
    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    func testParsesPairedJITSessions() throws {
        let log = """
        2026-04-25 10:00:00.000 PreviewHost (libcomp) Preview Service[101:cafe] info __previews_injection_perform_first_jit_link some
        2026-04-25 10:00:00.500 PreviewHost (libcomp) Preview Service[101:cafe] info __previews_injection_register_swift_extension_entry_section data
        2026-04-25 10:00:01.250 PreviewHost (libcomp) Preview Service[101:cafe] info __previews_injection_run_user_entrypoint complete
        2026-04-25 10:00:05.000 PreviewHost (libcomp) Preview Service[101:cafe] info __previews_injection_perform_first_jit_link rerun
        2026-04-25 10:00:07.500 PreviewHost (libcomp) Preview Service[101:cafe] info __previews_injection_run_user_entrypoint complete
        """
        let report = try PreviewLatencyMeasurer.parse(log, dateFormatter: Self.formatter())
        XCTAssertEqual(report.totalSessions, 2)
        XCTAssertEqual(report.latestPID, 101)
        XCTAssertEqual(report.latestTotalSeconds, 2.5, accuracy: 0.001)
        XCTAssertNil(report.latestRegisterSeconds)
        XCTAssertEqual(report.averageSeconds, (1.25 + 2.5) / 2, accuracy: 0.001)
        XCTAssertEqual(report.medianSeconds, (1.25 + 2.5) / 2, accuracy: 0.001)
        XCTAssertEqual(report.bestSeconds, 1.25, accuracy: 0.001)
        XCTAssertEqual(report.worstSeconds, 2.5, accuracy: 0.001)
    }

    func testThrowsWhenNoCompletedSessions() {
        let log = """
        2026-04-25 10:00:00.000 PreviewHost worker Foo[1:bar] info __previews_injection_perform_first_jit_link
        """
        XCTAssertThrowsError(try PreviewLatencyMeasurer.parse(log, dateFormatter: Self.formatter())) { error in
            guard let failure = error as? PreviewLatencyMeasurer.Failure else {
                XCTFail("expected Failure, got \(error)")
                return
            }
            XCTAssertTrue(failure.message.contains("No completed"))
        }
    }

    func testRegisterMarkerIncludedWhenPresent() throws {
        let log = """
        2026-04-25 10:00:00.000 PreviewHost worker Foo[42:bar] info __previews_injection_perform_first_jit_link
        2026-04-25 10:00:00.250 PreviewHost worker Foo[42:bar] info __previews_injection_register_swift_extension_entry_section
        2026-04-25 10:00:01.000 PreviewHost worker Foo[42:bar] info __previews_injection_run_user_entrypoint
        """
        let report = try PreviewLatencyMeasurer.parse(log, dateFormatter: Self.formatter())
        XCTAssertEqual(report.totalSessions, 1)
        XCTAssertEqual(try XCTUnwrap(report.latestRegisterSeconds), 0.25, accuracy: 0.001)
    }

    func testRenderProducesExpectedLines() {
        let report = PreviewLatencyMeasurer.Report(
            totalSessions: 3,
            latestProcess: "Preview",
            latestPID: 42,
            latestTotalSeconds: 1.234,
            latestRegisterSeconds: 0.567,
            averageSeconds: 1.0,
            medianSeconds: 1.0,
            bestSeconds: 0.5,
            worstSeconds: 2.0
        )
        let rendered = PreviewLatencyMeasurer.render(report)
        XCTAssertTrue(rendered.contains("Preview JIT sessions: 3"))
        XCTAssertTrue(rendered.contains("Latest host: Preview (pid 42)"))
        XCTAssertTrue(rendered.contains("Latest total: 1.234s"))
        XCTAssertTrue(rendered.contains("Latest first-link to register: 0.567s"))
        XCTAssertTrue(rendered.contains("Best total: 0.500s"))
    }
}
