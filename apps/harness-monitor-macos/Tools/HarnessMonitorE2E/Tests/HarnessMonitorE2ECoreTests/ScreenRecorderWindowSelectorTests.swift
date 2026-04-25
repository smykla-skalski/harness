import XCTest
@testable import HarnessMonitorE2ECore

@available(macOS 15.0, *)
final class ScreenRecorderWindowSelectorTests: XCTestCase {
    func testCaptureWindowSelectsMainHarnessMonitorWindowFromUITestHost() throws {
        let selected = try ScreenRecorderWindowSelector.captureWindow(from: [
            ScreenRecorderWindowCandidate(
                windowID: 1,
                title: "Harness Monitor",
                bundleIdentifier: "com.apple.finder",
                isOnScreen: true
            ),
            ScreenRecorderWindowCandidate(
                windowID: 2,
                title: "Preferences",
                bundleIdentifier: "io.harnessmonitor.app.ui-testing",
                isOnScreen: true
            ),
            ScreenRecorderWindowCandidate(
                windowID: 3,
                title: "Harness Monitor",
                bundleIdentifier: "io.harnessmonitor.app.ui-testing",
                isOnScreen: true
            ),
        ])

        XCTAssertEqual(selected.windowID, 3)
    }

    func testCaptureWindowSelectsMainHarnessMonitorWindowFromShippingApp() throws {
        let selected = try ScreenRecorderWindowSelector.captureWindow(from: [
            ScreenRecorderWindowCandidate(
                windowID: 10,
                title: "Agents",
                bundleIdentifier: "io.harnessmonitor.app",
                isOnScreen: true
            ),
            ScreenRecorderWindowCandidate(
                windowID: 11,
                title: "Harness Monitor",
                bundleIdentifier: "io.harnessmonitor.app",
                isOnScreen: true
            ),
        ])

        XCTAssertEqual(selected.windowID, 11)
    }

    func testCaptureWindowFailsWhenOnlyOffScreenMainWindowExists() {
        XCTAssertThrowsError(
            try ScreenRecorderWindowSelector.captureWindow(from: [
                ScreenRecorderWindowCandidate(
                    windowID: 21,
                    title: "Harness Monitor",
                    bundleIdentifier: "io.harnessmonitor.app.ui-testing",
                    isOnScreen: false
                ),
            ])
        ) { error in
            XCTAssertEqual(error as? ScreenRecorder.Failure, .monitorWindowNotFound)
        }
    }

    func testCaptureWindowFailsWhenMultipleMainHarnessMonitorWindowsAreShareable() {
        XCTAssertThrowsError(
            try ScreenRecorderWindowSelector.captureWindow(from: [
                ScreenRecorderWindowCandidate(
                    windowID: 30,
                    title: "Harness Monitor",
                    bundleIdentifier: "io.harnessmonitor.app.ui-testing",
                    isOnScreen: true
                ),
                ScreenRecorderWindowCandidate(
                    windowID: 31,
                    title: "Harness Monitor",
                    bundleIdentifier: "io.harnessmonitor.app",
                    isOnScreen: true
                ),
            ])
        ) { error in
            XCTAssertEqual(error as? ScreenRecorder.Failure, .ambiguousMonitorWindows(2))
        }
    }
}
