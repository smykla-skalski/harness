import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorPreferencesLayoutUITests: HarnessMonitorUITestCase {
  func testPreferencesOverviewUsesGroupedFormRowsAndCompactActionButtons() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    openSettings(in: app)
    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)
    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.actionTimeout))

    let endpointCard = element(in: app, identifier: Accessibility.preferencesEndpointCard)
    let versionCard = element(in: app, identifier: Accessibility.preferencesVersionCard)
    let launchdCard = element(in: app, identifier: Accessibility.preferencesLaunchdCard)
    let databaseSizeCard = element(in: app, identifier: Accessibility.preferencesDatabaseSizeCard)
    let liveSessionsCard = element(in: app, identifier: Accessibility.preferencesLiveSessionsCard)

    XCTAssertTrue(endpointCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(versionCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(launchdCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(databaseSizeCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(liveSessionsCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        (launchdCard.value as? String)?.contains("Running") == true
      }
    )

    let overviewRows = [endpointCard, versionCard, launchdCard, databaseSizeCard, liveSessionsCard]
    for row in overviewRows {
      XCTAssertLessThan(row.frame.height, 80)
    }

    for (previousRow, nextRow) in zip(overviewRows, overviewRows.dropFirst()) {
      XCTAssertLessThan(
        previousRow.frame.minY,
        nextRow.frame.minY,
        "Overview rows should stack vertically in the grouped form"
      )
    }

    let reconnect = frameElement(in: app, identifier: "\(Accessibility.reconnectButton).frame")
    let refresh = frameElement(
      in: app, identifier: "\(Accessibility.refreshDiagnosticsButton).frame")
    let start = frameElement(in: app, identifier: "\(Accessibility.startDaemonButton).frame")
    let install = frameElement(
      in: app,
      identifier: "\(Accessibility.installLaunchAgentButton).frame"
    )
    let remove = frameElement(
      in: app,
      identifier: "\(Accessibility.removeLaunchAgentButton).frame"
    )

    XCTAssertTrue(reconnect.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(refresh.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(start.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(install.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(remove.waitForExistence(timeout: Self.actionTimeout))

    assertEqualHeights([reconnect, refresh, start, install, remove], tolerance: 10)
    XCTAssertLessThan(start.frame.height, 62)
    XCTAssertLessThan(refresh.frame.height, 62)
  }

  func testPreferencesToolbarSeparatorIsSuppressed() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)
    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.actionTimeout))

    let separatorSuppressed = element(
      in: app,
      identifier: Accessibility.preferencesToolbarSeparatorSuppressed
    )
    XCTAssertTrue(
      separatorSuppressed.waitForExistence(timeout: Self.actionTimeout),
      "Settings window toolbar separator suppressor must be applied to prevent the seam between toolbar and content"
    )
    XCTAssertEqual(
      separatorSuppressed.label,
      "suppressed",
      "Separator suppressor marker should report 'suppressed'"
    )
  }

  func testPreferencesSidebarChromeMatchesNativeInsetLayout() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)

    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.actionTimeout))

    let settingsWindow = window(in: app, containing: preferencesPanel)
    XCTAssertTrue(settingsWindow.exists)
    let settingsToolbar = settingsWindow.toolbars.firstMatch
    XCTAssertTrue(settingsToolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertGreaterThan(
      settingsToolbar.buttons.count,
      0,
      "Settings split view should expose toolbar controls in native window chrome"
    )
    let leadingToolbarButton = settingsToolbar.buttons.element(boundBy: 0)
    XCTAssertTrue(leadingToolbarButton.exists)
    let generalSection = element(
      in: app,
      identifier: Accessibility.preferencesSectionButton("general")
    )
    XCTAssertTrue(generalSection.waitForExistence(timeout: Self.actionTimeout))
    let toolbarLeadingInset = leadingToolbarButton.frame.minX - settingsWindow.frame.minX
    let rowTopInset = generalSection.frame.minY - settingsWindow.frame.minY

    XCTAssertLessThan(
      toolbarLeadingInset,
      176,
      "Settings sidebar toggle should stay near the leading window chrome"
    )
    XCTAssertGreaterThan(
      rowTopInset,
      44,
      "Sidebar content should start below the native toolbar controls"
    )
    XCTAssertLessThan(
      rowTopInset,
      120,
      "Sidebar content should stay visually close to the toolbar"
    )
  }

}
