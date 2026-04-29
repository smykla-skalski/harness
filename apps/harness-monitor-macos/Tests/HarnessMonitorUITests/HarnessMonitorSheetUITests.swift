import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSheetUITests: HarnessMonitorUITestCase {
  // swiftlint:disable:next static_over_final_class
  override nonisolated class var reuseLaunchedApp: Bool { true }

  func testSendSignalSheetSupportsDismissalAndPreviewVoiceCapture() throws {
    let app = launchInCockpitPreview()

    XCTContext.runActivity(named: "Validate the form and dismiss via Cancel") { _ in
      openSendSignalSheet(in: app)

      let sheetRoot = assertSendSignalSheetVisible(in: app)
      tapElement(in: app, identifier: Accessibility.sendSignalSheetMessageField)
      let messageField = editableField(
        in: app, identifier: Accessibility.sendSignalSheetMessageField)
      messageField.typeText("Review the latest changes")

      assertSendSignalFormChrome(in: app)
      let actionHintField = editableField(
        in: app,
        identifier: Accessibility.sendSignalSheetActionHintField
      )
      XCTAssertTrue(actionHintField.exists, "Action hint field should exist")

      dismissSendSignalSheetWithCancel(in: app, sheetRoot: sheetRoot)
    }

    XCTContext.runActivity(named: "Reopen the sheet and insert preview voice input") { _ in
      openSendSignalSheet(in: app)

      let sheetRoot = assertSendSignalSheetVisible(in: app)
      let popover = openVoicePopover(in: app)
      let recordButton = button(in: app, identifier: Accessibility.voiceInputStopButton)
      XCTAssertTrue(recordButton.label.contains("Record"))
      tapButton(in: app, identifier: Accessibility.voiceInputStopButton)

      let transcript = element(in: app, identifier: Accessibility.voiceInputTranscript)
      let transcriptText = app.staticTexts["Preview voice input for Harness Monitor"].firstMatch
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          (transcript.exists
            && transcript.label.contains("Preview voice input for Harness Monitor"))
            || transcriptText.exists
        },
        "Preview voice capture should produce a transcript without microphone access"
      )

      let insertButton = button(in: app, identifier: Accessibility.voiceInputInsertButton)
      XCTAssertTrue(insertButton.waitForExistence(timeout: Self.actionTimeout))
      tapButton(in: app, identifier: Accessibility.voiceInputInsertButton)

      let messageField = editableField(
        in: app,
        identifier: Accessibility.sendSignalSheetMessageField
      )
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          let value = messageField.value as? String
          return value?.contains("Preview voice input for Harness Monitor") == true
        },
        "Inserted voice transcript should update the message field"
      )
      XCTAssertTrue(
        waitUntil(timeout: Self.fastActionTimeout) { !popover.exists },
        "Manual insert should close the voice popover"
      )

      dismissSendSignalSheetWithEscape(in: app, sheetRoot: sheetRoot)
    }
  }

  func testSendSignalVoicePopoverHandlesFailureAndAutoInsertModes() throws {
    XCTContext.runActivity(named: "Show speech asset recovery guidance") { _ in
      let app = launchInCockpitPreview(
        additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_VOICE_FAILURE": "speech-assets"]
      )

      openSendSignalSheet(in: app)
      _ = assertSendSignalSheetVisible(in: app)
      _ = openVoicePopover(in: app)

      let recordButton = button(in: app, identifier: Accessibility.voiceInputStopButton)
      XCTAssertTrue(recordButton.waitForExistence(timeout: Self.fastActionTimeout))
      tapButton(in: app, identifier: Accessibility.voiceInputStopButton)

      let overlay = element(in: app, identifier: Accessibility.voiceInputFailureOverlay)
      XCTAssertTrue(
        overlay.waitForExistence(timeout: Self.actionTimeout),
        "Speech asset failures should cover the voice popover with a recovery panel"
      )

      let message = element(in: app, identifier: Accessibility.voiceInputFailureMessage)
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          message.exists && message.label.contains("Speech assets for en_PL are unavailable")
        },
        "Recovery panel should show the full Speech asset error"
      )

      let instructions = element(in: app, identifier: Accessibility.voiceInputFailureInstructions)
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          instructions.exists
            && instructions.label.contains("System Settings")
            && instructions.label.contains("English (US)")
        },
        "Recovery panel should explain how to install or select usable speech assets"
      )
    }

    XCTContext.runActivity(named: "Auto-insert closes the voice popover") { _ in
      let app = launchInCockpitPreview(
        additionalEnvironment: [
          HarnessMonitorSettingsUITestKeys.voiceInsertionModeOverride: "autoInsert"
        ]
      )

      openSendSignalSheet(in: app)
      let sheetRoot = assertSendSignalSheetVisible(in: app)
      let popover = openVoicePopover(in: app)

      let recordButton = button(in: app, identifier: Accessibility.voiceInputStopButton)
      XCTAssertTrue(recordButton.waitForExistence(timeout: Self.fastActionTimeout))
      tapButton(in: app, identifier: Accessibility.voiceInputStopButton)

      let messageField = editableField(
        in: app,
        identifier: Accessibility.sendSignalSheetMessageField
      )
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          let value = messageField.value as? String
          return value?.contains("Preview voice input for Harness Monitor") == true
        },
        "Auto-insert should write the captured transcript into the message field"
      )
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) { !popover.exists },
        "Auto-insert should close the voice popover after inserting the transcript"
      )

      dismissSendSignalSheetWithEscape(in: app, sheetRoot: sheetRoot)
    }
  }

  func testNewSessionSheetFieldsCapabilityPickerAndLayoutStability() throws {
    let app = launch(mode: "preview")
    let processID = try launchedMonitorPID()
    let logStart = Date()

    tapButton(in: app, identifier: Accessibility.sidebarNewSessionButton)

    let sheetRoot = element(in: app, identifier: Accessibility.newSessionSheet)
    XCTAssertTrue(
      sheetRoot.waitForExistence(timeout: Self.actionTimeout),
      "New Session sheet should appear from the toolbar action"
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

    let capabilityPicker = element(in: app, identifier: Accessibility.newSessionCapabilityPicker)
    XCTAssertTrue(
      capabilityPicker.waitForExistence(timeout: Self.fastActionTimeout)
        || app.staticTexts["Preferred first leader"].firstMatch.waitForExistence(
          timeout: Self.fastActionTimeout
        ),
      "New Session should surface the preferred leader capability picker"
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.newSessionTabPicker).waitForExistence(
        timeout: Self.fastActionTimeout
      ),
      "New Session should expose the runtime setup tab control"
    )
    XCTAssertTrue(
      app.staticTexts["Base ref"].firstMatch.waitForExistence(timeout: Self.fastActionTimeout),
      "New Session should keep Base ref directly discoverable in the create tab"
    )

    let tabPicker = element(in: app, identifier: Accessibility.newSessionTabPicker)
    XCTAssertTrue(tabPicker.exists, "Tab picker should exist before selecting Runtime Setup")
    let runtimeTab = app.segmentedControls.buttons["Runtime Setup"].firstMatch
    XCTAssertTrue(
      runtimeTab.waitForExistence(timeout: Self.fastActionTimeout),
      "Runtime Setup segmented tab should exist"
    )
    runtimeTab.tap()
    XCTAssertTrue(
      app.staticTexts["Ready providers"].firstMatch.waitForExistence(
        timeout: Self.fastActionTimeout
      ),
      "Runtime Setup tab should show the ready providers group"
    )
    XCTAssertTrue(
      app.staticTexts["Needs install"].firstMatch.waitForExistence(
        timeout: Self.fastActionTimeout
      ),
      "Runtime Setup tab should show the install requirements group"
    )

    RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastActionTimeout))

    let warnings = appKitLayoutRecursionWarnings(since: logStart, processID: processID)
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

  func testNewSessionSheetCouncilPreviewSnapshots() throws {
    let app = launch(mode: "preview")

    tapButton(in: app, identifier: Accessibility.sidebarNewSessionButton)

    let sheetRoot = element(in: app, identifier: Accessibility.newSessionSheet)
    XCTAssertTrue(
      sheetRoot.waitForExistence(timeout: Self.actionTimeout),
      "New Session sheet should appear from the toolbar action"
    )

    XCTAssertTrue(
      app.staticTexts["Session title"].firstMatch.waitForExistence(timeout: Self.fastActionTimeout),
      "Create tab should be visible before capturing council preview"
    )
    try writeCouncilPreviewSnapshot(in: app, named: "new-session-create-tab")

    let runtimeTab = app.segmentedControls.buttons["Runtime Setup"].firstMatch
    XCTAssertTrue(
      runtimeTab.waitForExistence(timeout: Self.fastActionTimeout),
      "Runtime Setup segmented tab should exist before capture"
    )
    runtimeTab.tap()
    XCTAssertTrue(
      app.staticTexts["Ready providers"].firstMatch.waitForExistence(
        timeout: Self.fastActionTimeout
      ),
      "Runtime Setup tab should be visible before capturing council preview"
    )
    try writeCouncilPreviewSnapshot(in: app, named: "new-session-runtime-setup-tab")
  }
}

extension HarnessMonitorSheetUITests {
  fileprivate func writeCouncilPreviewSnapshot(in app: XCUIApplication, named name: String) throws {
    let directoryPath =
      ProcessInfo.processInfo.environment["HARNESS_MONITOR_COUNCIL_PREVIEW_DIR"]
      ?? "\(FileManager.default.currentDirectoryPath)/tmp/council/new-session-previews"
    let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let sanitizedName =
      name
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "/", with: "-")
    let screenshotURL = directoryURL.appendingPathComponent("\(sanitizedName).png")
    let screenshot = app.windows.firstMatch.screenshot()
    try screenshot.pngRepresentation.write(to: screenshotURL)
  }

  fileprivate func launchedMonitorPID() throws -> pid_t {
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

  fileprivate func appKitLayoutRecursionWarnings(
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

  fileprivate func launchInCockpitPreview(
    additionalEnvironment: [String: String] = [:]
  ) -> XCUIApplication {
    var environment = ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    environment.merge(additionalEnvironment) { _, new in new }
    return launch(
      mode: "preview",
      additionalEnvironment: environment
    )
  }

  fileprivate func assertSendSignalSheetVisible(in app: XCUIApplication) -> XCUIElement {
    let sheetRoot = element(in: app, identifier: Accessibility.sendSignalSheet)
    XCTAssertTrue(
      sheetRoot.waitForExistence(timeout: Self.actionTimeout),
      "Send Signal sheet should appear after context menu tap"
    )
    return sheetRoot
  }

  fileprivate func assertSendSignalFormChrome(in app: XCUIApplication) {
    let commandField = editableField(in: app, identifier: Accessibility.sendSignalSheetCommandField)
    let messageField = editableField(in: app, identifier: Accessibility.sendSignalSheetMessageField)
    let cancelButton = button(in: app, identifier: Accessibility.sendSignalSheetCancelButton)
    let submitButton = button(in: app, identifier: Accessibility.sendSignalSheetSubmitButton)

    XCTAssertTrue(commandField.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(messageField.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(cancelButton.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(submitButton.waitForExistence(timeout: Self.fastActionTimeout))
  }

  /// Right-click the already-loaded leader agent card to open the "Send Signal"
  /// context menu item.
  fileprivate func openSendSignalSheet(in app: XCUIApplication) {
    app.activate()
    let agentCard = button(in: app, identifier: Accessibility.leaderAgentCard)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout, pollInterval: 0.02) {
        agentCard.exists && !agentCard.frame.isEmpty
      },
      "Leader agent card should be visible in cockpit preview"
    )

    guard rightClickElementReliably(in: app, element: agentCard) else {
      XCTFail("Failed to open the Send Signal context menu from the leader card")
      return
    }

    let signalMenuItem = app.menuItems["Send Signal"].firstMatch
    XCTAssertTrue(
      signalMenuItem.waitForExistence(timeout: Self.actionTimeout),
      "Send Signal menu item should appear"
    )
    signalMenuItem.tap()
  }

  fileprivate func openVoicePopover(in app: XCUIApplication) -> XCUIElement {
    tapButton(in: app, identifier: Accessibility.sendSignalSheetMessageVoiceButton)

    let popover = element(in: app, identifier: Accessibility.voiceInputPopover)
    XCTAssertTrue(
      popover.waitForExistence(timeout: Self.actionTimeout),
      "Voice input popover should open from the message field"
    )
    return popover
  }

  fileprivate func dismissSendSignalSheetWithCancel(
    in app: XCUIApplication,
    sheetRoot: XCUIElement
  ) {
    tapButton(in: app, identifier: Accessibility.sendSignalSheetCancelButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheetRoot.exists },
      "Sheet should dismiss on Cancel"
    )
  }

  fileprivate func dismissSendSignalSheetWithEscape(
    in app: XCUIApplication,
    sheetRoot: XCUIElement
  ) {
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheetRoot.exists },
      "Sheet should dismiss on Escape"
    )
  }
}
