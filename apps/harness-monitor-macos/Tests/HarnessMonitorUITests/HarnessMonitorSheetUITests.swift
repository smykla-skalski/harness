import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSheetUITests: HarnessMonitorUITestCase {
  func testSendSignalSheetPresentsAndDismissesWithEscape() throws {
    let app = launchInCockpitPreview()

    openSendSignalSheet(in: app)

    // Verify sheet appeared.
    let sheetRoot = element(in: app, identifier: Accessibility.sendSignalSheet)
    XCTAssertTrue(
      sheetRoot.waitForExistence(timeout: Self.actionTimeout),
      "Send Signal sheet should appear after context menu tap"
    )

    // Verify form fields exist.
    let commandField = editableField(in: app, identifier: Accessibility.sendSignalSheetCommandField)
    let messageField = editableField(in: app, identifier: Accessibility.sendSignalSheetMessageField)
    let cancelButton = button(in: app, identifier: Accessibility.sendSignalSheetCancelButton)
    let submitButton = button(in: app, identifier: Accessibility.sendSignalSheetSubmitButton)

    XCTAssertTrue(commandField.exists, "Command field should exist")
    XCTAssertTrue(messageField.exists, "Message field should exist")
    XCTAssertTrue(cancelButton.exists, "Cancel button should exist")
    XCTAssertTrue(submitButton.exists, "Submit button should exist")

    // Dismiss with Escape.
    app.typeKey(.escape, modifierFlags: [])
    RunLoop.current.run(until: Date.now.addingTimeInterval(0.3))

    XCTAssertTrue(
      waitUntil(timeout: 2) { !sheetRoot.exists },
      "Sheet should dismiss on Escape"
    )
  }

  func testSendSignalSheetDismissesWithCancelButton() throws {
    let app = launchInCockpitPreview()

    openSendSignalSheet(in: app)

    let sheetRoot = element(in: app, identifier: Accessibility.sendSignalSheet)
    XCTAssertTrue(sheetRoot.waitForExistence(timeout: Self.actionTimeout))

    // Dismiss via Cancel button.
    let cancelButton = button(in: app, identifier: Accessibility.sendSignalSheetCancelButton)
    XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
    tapViaCoordinate(in: app, element: cancelButton)

    XCTAssertTrue(
      waitUntil(timeout: 2) { !sheetRoot.exists },
      "Sheet should dismiss on Cancel"
    )
  }

  func testSendSignalSheetFormInteraction() throws {
    let app = launchInCockpitPreview()

    openSendSignalSheet(in: app)

    let sheetRoot = element(in: app, identifier: Accessibility.sendSignalSheet)
    XCTAssertTrue(sheetRoot.waitForExistence(timeout: Self.actionTimeout))

    // Command field should have default value "inject_context".
    let commandField = editableField(in: app, identifier: Accessibility.sendSignalSheetCommandField)
    XCTAssertTrue(commandField.waitForExistence(timeout: 2))

    // Type into message field.
    let messageField = editableField(in: app, identifier: Accessibility.sendSignalSheetMessageField)
    XCTAssertTrue(messageField.waitForExistence(timeout: 2))
    tapViaCoordinate(in: app, element: messageField)
    messageField.typeText("Review the latest changes")

    // Verify submit button exists and is accessible.
    let submitButton = button(in: app, identifier: Accessibility.sendSignalSheetSubmitButton)
    XCTAssertTrue(submitButton.exists, "Submit button should exist")

    // Verify action hint field exists.
    let actionHintField = editableField(
      in: app,
      identifier: Accessibility.sendSignalSheetActionHintField
    )
    XCTAssertTrue(actionHintField.exists, "Action hint field should exist")

    // Clean up.
    app.typeKey(.escape, modifierFlags: [])
  }

  func testNewSessionSheetUsesStackedEditableFields() throws {
    let app = launch(mode: "preview")

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
    XCTAssertTrue(
      app.staticTexts["Base ref"].firstMatch.waitForExistence(timeout: Self.fastActionTimeout),
      "New Session should keep the Base ref field directly discoverable"
    )

    let baseRefField = editableField(in: app, identifier: Accessibility.newSessionBaseRef)
    XCTAssertTrue(
      baseRefField.waitForExistence(timeout: Self.fastActionTimeout),
      "Base ref should remain directly editable in the sheet"
    )
  }

  func testNewSessionSheetDoesNotEmitLayoutRecursionWarning() throws {
    let app = launch(mode: "preview")
    let processID = try launchedMonitorPID()
    let logStart = Date()

    tapButton(in: app, identifier: Accessibility.sidebarNewSessionButton)

    let sheetRoot = element(in: app, identifier: Accessibility.newSessionSheet)
    XCTAssertTrue(
      sheetRoot.waitForExistence(timeout: Self.actionTimeout),
      "New Session sheet should appear before checking AppKit warnings"
    )
    XCTAssertTrue(
      app.staticTexts["Session title"].firstMatch.waitForExistence(timeout: Self.fastActionTimeout),
      "New Session should finish presenting before log inspection"
    )

    RunLoop.current.run(until: Date.now.addingTimeInterval(1.0))

    let warnings = appKitLayoutRecursionWarnings(since: logStart, processID: processID)
    XCTAssertTrue(
      warnings.isEmpty,
      "Opening New Session should not emit the AppKit layout recursion warning.\n\(warnings)"
    )
  }

  func testSendSignalVoicePopoverRecordsPreviewTranscript() throws {
    let app = launchInCockpitPreview()

    openSendSignalSheet(in: app)

    let voiceButton = button(in: app, identifier: Accessibility.sendSignalSheetMessageVoiceButton)
    XCTAssertTrue(voiceButton.waitForExistence(timeout: Self.actionTimeout))
    tapViaCoordinate(in: app, element: voiceButton)

    let popover = element(in: app, identifier: Accessibility.voiceInputPopover)
    XCTAssertTrue(
      popover.waitForExistence(timeout: Self.actionTimeout),
      "Voice input popover should open from the message field"
    )

    let recordButton = button(in: app, identifier: Accessibility.voiceInputStopButton)
    XCTAssertTrue(recordButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(recordButton.label.contains("Record"))
    tapViaCoordinate(in: app, element: recordButton)

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
    tapViaCoordinate(in: app, element: insertButton)

    let messageField = editableField(in: app, identifier: Accessibility.sendSignalSheetMessageField)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let value = messageField.value as? String
        return value?.contains("Preview voice input for Harness Monitor") == true
      },
      "Inserted voice transcript should update the message field"
    )
  }

  func testSendSignalVoicePopoverSurfacesSpeechAssetRecovery() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_VOICE_FAILURE": "speech-assets"]
    )

    openSendSignalSheet(in: app)

    let voiceButton = button(in: app, identifier: Accessibility.sendSignalSheetMessageVoiceButton)
    XCTAssertTrue(voiceButton.waitForExistence(timeout: Self.actionTimeout))
    tapViaCoordinate(in: app, element: voiceButton)

    let recordButton = button(in: app, identifier: Accessibility.voiceInputStopButton)
    XCTAssertTrue(recordButton.waitForExistence(timeout: Self.actionTimeout))
    tapViaCoordinate(in: app, element: recordButton)

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

  func testSendSignalVoicePopoverAutoInsertsWhenConfigured() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        HarnessMonitorSettingsUITestKeys.voiceInsertionModeOverride: "autoInsert"
      ]
    )

    openSendSignalSheet(in: app)

    let voiceButton = button(in: app, identifier: Accessibility.sendSignalSheetMessageVoiceButton)
    XCTAssertTrue(voiceButton.waitForExistence(timeout: Self.actionTimeout))
    tapViaCoordinate(in: app, element: voiceButton)

    let popover = element(in: app, identifier: Accessibility.voiceInputPopover)
    XCTAssertTrue(popover.waitForExistence(timeout: Self.actionTimeout))

    let recordButton = button(in: app, identifier: Accessibility.voiceInputStopButton)
    XCTAssertTrue(recordButton.waitForExistence(timeout: Self.actionTimeout))
    tapViaCoordinate(in: app, element: recordButton)

    let messageField = editableField(in: app, identifier: Accessibility.sendSignalSheetMessageField)
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
  }
}

extension HarnessMonitorSheetUITests {
  fileprivate func launchedMonitorPID() throws -> pid_t {
    let candidates = NSRunningApplication.runningApplications(
      withBundleIdentifier: Self.uiTestHostBundleIdentifier)
    guard let mostRecent = candidates.max(by: { lhs, rhs in
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

    let stdout = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    let stderr = String(
      decoding: errors.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    if process.terminationStatus != 0 {
      XCTFail("log show exited with status \(process.terminationStatus): \(stderr)")
    }
    let matchingLines = stdout
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

    agentCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()

    let signalMenuItem = app.menuItems["Send Signal"].firstMatch
    XCTAssertTrue(
      signalMenuItem.waitForExistence(timeout: Self.actionTimeout),
      "Send Signal menu item should appear"
    )
    signalMenuItem.tap()
  }

  fileprivate func tapViaCoordinate(in app: XCUIApplication, element: XCUIElement) {
    guard tapElementReliably(in: app, element: element) else {
      XCTFail("Cannot resolve coordinate for \(element)")
      return
    }
  }
}
