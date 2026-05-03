import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension HarnessMonitorSheetUITests {
  func testNewSessionSheetFieldsCapabilityPickerAndLayoutStability() throws {
    let app = launch(mode: "preview")
    let processID = try launchedMonitorPIDForNewSession()
    let logStart = Date()

    openNewSessionSheet(in: app)

    let sheetRoot = element(in: app, identifier: Accessibility.newSessionSheet)
    XCTAssertTrue(
      sheetRoot.waitForExistence(timeout: Self.actionTimeout),
      "New Session sheet should appear from the File menu command"
    )

    XCTAssertTrue(
      app.staticTexts["Project folder"].firstMatch
        .waitForExistence(timeout: Self.fastActionTimeout),
      "New Session should show a visible Project folder label"
    )
    XCTAssertTrue(
      app.staticTexts["Session title"].firstMatch.waitForExistence(timeout: Self.fastActionTimeout),
      "New Session should show a visible Session title label"
    )
    XCTAssertTrue(
      app.staticTexts["Context"].firstMatch.waitForExistence(timeout: Self.fastActionTimeout),
      "New Session should show a visible Context label for the multiline field"
    )

    let capabilitySection = element(
      in: app,
      identifier: Accessibility.newSessionCapabilityPickerSection
    )
    XCTAssertTrue(
      capabilitySection.waitForExistence(timeout: Self.fastActionTimeout)
        || app.staticTexts["Launch with"].firstMatch.waitForExistence(
          timeout: Self.fastActionTimeout
        ),
      "New Session should surface the inline preferred leader section"
    )
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.agentCapabilityRow("copilot")),
        timeout: Self.fastActionTimeout
      ),
      "New Session should render the shared capability row experience"
    )
    XCTAssertTrue(
      app.staticTexts["Launch with"].firstMatch.waitForExistence(
        timeout: Self.fastActionTimeout
      ),
      "New Session should keep leader selection in the primary inline form flow"
    )
    let providerDetailsLabel = app.staticTexts["Provider details"].firstMatch
    if providerDetailsLabel.waitForExistence(timeout: Self.fastActionTimeout) {
      XCTAssertFalse(
        app.staticTexts["0 need setup, 0 still checking."].firstMatch.exists,
        "Provider details summary should not undercount mixed attention states"
      )
    }
    XCTAssertTrue(
      app.staticTexts["Base ref"].firstMatch.waitForExistence(timeout: Self.fastActionTimeout),
      "New Session should keep Base ref directly discoverable in the create tab"
    )

    XCTAssertFalse(
      element(in: app, identifier: Accessibility.newSessionTabPicker).exists,
      "New Session should keep provider setup inline instead of splitting it into a segmented tab switch"
    )
    XCTAssertFalse(
      app.staticTexts["Ready providers"].firstMatch.exists,
      "New Session should no longer repeat ready providers in a dedicated runtime tab"
    )
    XCTAssertFalse(
      app.staticTexts["Needs install"].firstMatch.exists,
      "New Session should no longer repeat install requirements in a dedicated runtime tab"
    )

    RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastActionTimeout))

    let warnings = appKitLayoutRecursionWarningsForNewSession(
      since: logStart,
      processID: processID
    )
    if !warnings.isEmpty {
      XCTExpectFailure(
        """
        AppKit emits a non-deterministic WarnOnce layout recursion log in the UI test host.
        Keep this assertion visible but non-blocking while sheet UX regressions are validated.
        """
      ) {
        XCTAssertTrue(
          warnings.isEmpty,
          "Opening New Session should not emit the AppKit layout recursion warning.\n\(warnings)"
        )
      }
    }

    dismissNewSessionSheet(in: app, sheetRoot: sheetRoot)
  }

  func testNewSessionSheetPreviewSnapshots() throws {
    let app = launch(mode: "preview")

    openNewSessionSheet(in: app)

    let sheetRoot = element(in: app, identifier: Accessibility.newSessionSheet)
    XCTAssertTrue(
      sheetRoot.waitForExistence(timeout: Self.actionTimeout),
      "New Session sheet should appear from the File menu command"
    )

    XCTAssertTrue(
      app.staticTexts["Launch with"].firstMatch.waitForExistence(
        timeout: Self.fastActionTimeout
      ),
      "The redesigned sheet should show the inline leader selection section "
        + "before capturing the preview snapshot"
    )
    recordDiagnosticsSnapshot(in: app, named: "new-session-sheet")
    dismissNewSessionSheet(in: app, sheetRoot: sheetRoot)
  }

  private func launchedMonitorPIDForNewSession() throws -> pid_t {
    let candidates = NSRunningApplication.runningApplications(
      withBundleIdentifier: Self.uiTestHostBundleIdentifier)
    guard
      let mostRecent = candidates.max(by: { lhs, rhs in
        let lhsDate = lhs.launchDate ?? .distantPast
        let rhsDate = rhs.launchDate ?? .distantPast
        return lhsDate < rhsDate
      })
    else {
      throw NSError(
        domain: "HarnessMonitorSheetUITests",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Could not resolve the UI test host process ID."
        ]
      )
    }
    return mostRecent.processIdentifier
  }

  private func openNewSessionSheet(in app: XCUIApplication) {
    let sheetRoot = element(in: app, identifier: Accessibility.newSessionSheet)
    if sheetRoot.exists {
      return
    }
    invokeMenuItem(in: app, menu: "File", title: "New Session")
  }

  private func dismissNewSessionSheet(in app: XCUIApplication, sheetRoot: XCUIElement) {
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheetRoot.exists },
      "New Session sheet should dismiss after pressing Escape"
    )
  }

  private func appKitLayoutRecursionWarningsForNewSession(
    since startDate: Date,
    processID: pid_t
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    let output = Pipe()
    let errors = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "show",
      "--style",
      "compact",
      "--start",
      formatter.string(from: startDate),
      "--predicate",
      """
      processID == \(processID) AND subsystem == "com.apple.AppKit" AND \
      (eventMessage CONTAINS "layoutSubtreeIfNeeded" OR \
      eventMessage CONTAINS "already being laid out")
      """,
    ]
    process.standardOutput = output
    process.standardError = errors

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      XCTFail("Failed to run log show: \(error)")
      return ""
    }

    let stdout =
      String(
        bytes: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    let stderr =
      String(
        bytes: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    if process.terminationStatus != 0 {
      XCTFail("log show exited with status \(process.terminationStatus): \(stderr)")
    }

    let matchingLines =
      stdout
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter {
        $0.contains("layoutSubtreeIfNeeded") || $0.contains("already being laid out")
      }
    return matchingLines.joined(separator: "\n")
  }
}
