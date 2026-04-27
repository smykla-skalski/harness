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

  func testCaptureWindowSelectsDashboardWindowFromUITestHost() throws {
    let selected = try ScreenRecorderWindowSelector.captureWindow(from: [
      ScreenRecorderWindowCandidate(
        windowID: 40,
        title: "Agents",
        bundleIdentifier: "io.harnessmonitor.app.ui-testing",
        isOnScreen: true
      ),
      ScreenRecorderWindowCandidate(
        windowID: 41,
        title: "Dashboard",
        bundleIdentifier: "io.harnessmonitor.app.ui-testing",
        isOnScreen: true
      ),
    ])

    XCTAssertEqual(selected.windowID, 41)
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
        )
      ])
    ) { error in
      XCTAssertEqual(error as? ScreenRecorder.Failure, .monitorWindowNotFound)
    }
  }

  func testCaptureWindowSelectsShippingAppWindowWhenBothShareableHarnessMonitorWindowsAreVisible()
    throws
  {
    let selected = try ScreenRecorderWindowSelector.captureWindow(from: [
      ScreenRecorderWindowCandidate(
        windowID: 30,
        title: "Session Cockpit",
        bundleIdentifier: "io.harnessmonitor.app.ui-testing",
        isOnScreen: true
      ),
      ScreenRecorderWindowCandidate(
        windowID: 31,
        title: "Session Cockpit",
        bundleIdentifier: "io.harnessmonitor.app",
        isOnScreen: true
      ),
    ])

    XCTAssertEqual(selected.windowID, 31)
  }

  func testCaptureWindowFailsWhenMultipleShippingAppMainWindowsAreShareable() {
    XCTAssertThrowsError(
      try ScreenRecorderWindowSelector.captureWindow(from: [
        ScreenRecorderWindowCandidate(
          windowID: 32,
          title: "Harness Monitor",
          bundleIdentifier: "io.harnessmonitor.app",
          isOnScreen: true
        ),
        ScreenRecorderWindowCandidate(
          windowID: 33,
          title: "Harness Monitor",
          bundleIdentifier: "io.harnessmonitor.app",
          isOnScreen: true
        ),
      ])
    ) { error in
      XCTAssertEqual(error as? ScreenRecorder.Failure, .ambiguousMonitorWindows(2))
    }
  }

  func testCaptureWindowSelectsByProcessIDWhenRequiredEvenWithMultipleUITestingHostsRunning()
    throws
  {
    let selected = try ScreenRecorderWindowSelector.captureWindow(
      from: [
        ScreenRecorderWindowCandidate(
          windowID: 100,
          title: "Dashboard",
          bundleIdentifier: "io.harnessmonitor.app.ui-testing",
          processID: 9001,
          isOnScreen: true
        ),
        ScreenRecorderWindowCandidate(
          windowID: 101,
          title: "Dashboard",
          bundleIdentifier: "io.harnessmonitor.app.ui-testing",
          processID: 9002,
          isOnScreen: true
        ),
      ],
      requireProcessID: 9002
    )

    XCTAssertEqual(selected.windowID, 101)
  }

  func testCaptureWindowIgnoresShippingAppWhenRequireProcessIDPointsAtUITestingHost() throws {
    let selected = try ScreenRecorderWindowSelector.captureWindow(
      from: [
        ScreenRecorderWindowCandidate(
          windowID: 200,
          title: "Dashboard",
          bundleIdentifier: "io.harnessmonitor.app",
          processID: 5000,
          isOnScreen: true
        ),
        ScreenRecorderWindowCandidate(
          windowID: 201,
          title: "Dashboard",
          bundleIdentifier: "io.harnessmonitor.app.ui-testing",
          processID: 9999,
          isOnScreen: true
        ),
      ],
      requireProcessID: 9999
    )

    XCTAssertEqual(selected.windowID, 201)
  }

  func testCaptureWindowFailsWhenNoCandidateMatchesRequiredProcessID() {
    XCTAssertThrowsError(
      try ScreenRecorderWindowSelector.captureWindow(
        from: [
          ScreenRecorderWindowCandidate(
            windowID: 300,
            title: "Dashboard",
            bundleIdentifier: "io.harnessmonitor.app.ui-testing",
            processID: 1000,
            isOnScreen: true
          )
        ],
        requireProcessID: 2000
      )
    ) { error in
      XCTAssertEqual(error as? ScreenRecorder.Failure, .monitorWindowNotFound)
    }
  }

  func testCaptureWindowSkipsCandidateWithMatchingPidButOffScreen() {
    XCTAssertThrowsError(
      try ScreenRecorderWindowSelector.captureWindow(
        from: [
          ScreenRecorderWindowCandidate(
            windowID: 400,
            title: "Dashboard",
            bundleIdentifier: "io.harnessmonitor.app.ui-testing",
            processID: 4242,
            isOnScreen: false
          )
        ],
        requireProcessID: 4242
      )
    ) { error in
      XCTAssertEqual(error as? ScreenRecorder.Failure, .monitorWindowNotFound)
    }
  }

  func testCaptureWindowSkipsCandidateWithMatchingPidButNonMainTitle() {
    XCTAssertThrowsError(
      try ScreenRecorderWindowSelector.captureWindow(
        from: [
          ScreenRecorderWindowCandidate(
            windowID: 500,
            title: "Preferences",
            bundleIdentifier: "io.harnessmonitor.app.ui-testing",
            processID: 5252,
            isOnScreen: true
          )
        ],
        requireProcessID: 5252
      )
    ) { error in
      XCTAssertEqual(error as? ScreenRecorder.Failure, .monitorWindowNotFound)
    }
  }
}
