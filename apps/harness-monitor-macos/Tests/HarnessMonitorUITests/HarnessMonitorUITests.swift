import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility
private let textSizeOverrideKey = "HARNESS_MONITOR_TEXT_SIZE_OVERRIDE"

@MainActor
final class HarnessMonitorUITests: HarnessMonitorUITestCase {
  func testPreviewModeLoadsDashboardAndOpensCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    if !waitForElement(sessionRow, timeout: Self.fastActionTimeout) {
      attachWindowScreenshot(in: app, named: "preview-session-row-missing")
    }
    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))

    tapPreviewSession(in: app)

    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(waitForElement(observeSummaryButton, timeout: Self.fastActionTimeout))
  }

  func testDegradedPersistenceModeShowsWarningAndHidesPersistenceControls() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE": "1"]
    )

    let persistenceBanner = element(in: app, identifier: Accessibility.persistenceBanner)
    let sessionRow = previewSessionTrigger(in: app)
    let clearSearchHistoryButton = element(
      in: app,
      identifier: Accessibility.sidebarClearSearchHistoryButton
    )

    XCTAssertTrue(persistenceBanner.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(clearSearchHistoryButton.exists)

    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.taskUICard)

    let notesUnavailable = element(in: app, identifier: Accessibility.taskNotesUnavailable)
    XCTAssertTrue(notesUnavailable.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(element(in: app, identifier: Accessibility.taskNoteField).exists)
    XCTAssertFalse(element(in: app, identifier: Accessibility.taskNoteAddButton).exists)
  }

  func testObserveSummaryIsAvailableInSessionCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let tasks = app.staticTexts["Tasks"]
    let signals = app.staticTexts["Signals"]
    XCTAssertTrue(tasks.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(signals.waitForExistence(timeout: Self.actionTimeout))

    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.actionTimeout))
    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    XCTAssertTrue(tasks.exists)
    XCTAssertTrue(signals.exists)
  }

  func testEmptyCockpitShowsSharedEmptyStateRowsAcrossAllSections() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "empty-cockpit"]
    )

    let tasksEmpty = element(in: app, identifier: Accessibility.sessionEmptyState("tasks"))
    let agentsEmpty = element(in: app, identifier: Accessibility.sessionEmptyState("agents"))
    let signalsEmpty = element(in: app, identifier: Accessibility.sessionEmptyState("signals"))
    let timelineEmpty = element(in: app, identifier: Accessibility.sessionEmptyState("timeline"))

    XCTAssertTrue(tasksEmpty.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(agentsEmpty.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(signalsEmpty.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(timelineEmpty.waitForExistence(timeout: Self.actionTimeout))

    XCTAssertEqual(tasksEmpty.label, "No tasks right now")
    XCTAssertEqual(agentsEmpty.label, "No agents yet. Join a leader to activate this session.")
    XCTAssertEqual(signalsEmpty.label, "No signals right now")
    XCTAssertEqual(timelineEmpty.label, "No activity right now")
    XCTAssertFalse(element(in: app, identifier: Accessibility.sessionTimelinePagination).exists)
  }

  func testTaskDropCockpitStartsWithoutPreDragFeedback() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "task-drop"]
    )

    let task = element(in: app, identifier: Accessibility.taskDropQueueCard)
    let worker = element(in: app, identifier: Accessibility.workerAgentCard)
    let feedback = element(
      in: app,
      identifier: Accessibility.sessionAgentTaskDropFeedback("worker-codex")
    )
    XCTAssertTrue(
      task.waitForExistence(timeout: Self.actionTimeout)
    )
    XCTAssertTrue(worker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(feedback.exists)
  }

  func testToolbarSurvivesSidebarToggle() throws {
    let app = launch(mode: "preview")

    let sidebarToggle = sidebarToggleButton(in: app)
    let refreshButton = toolbarButton(in: app, identifier: Accessibility.refreshButton)
    let sidebarShellQuery = app.otherElements
      .matching(identifier: Accessibility.sidebarShellFrame)
    let sidebarShell = sidebarShellQuery.firstMatch

    XCTAssertTrue(sidebarToggle.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(refreshButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebarShell.waitForExistence(timeout: Self.actionTimeout))
    let initialSidebarWidth = sidebarShell.frame.width
    XCTAssertGreaterThan(initialSidebarWidth, 200)
    let refreshToolbarButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.refreshButton
    )
    let visibleRefreshButtons = refreshToolbarButtons
      .allElementsBoundByIndex
      .filter { $0.exists && $0.isHittable }
    XCTAssertGreaterThanOrEqual(visibleRefreshButtons.count, 1)
    XCTAssertTrue(refreshButton.isHittable)

    sidebarToggle.tap()

    XCTAssertTrue(
      waitUntil {
        guard let collapsedSidebar = sidebarShellQuery.allElementsBoundByIndex.first else {
          return true
        }
        return collapsedSidebar.frame.width < max(120, initialSidebarWidth * 0.5)
      }
    )
    XCTAssertTrue(refreshButton.exists)
    XCTAssertTrue(refreshButton.isHittable)

    sidebarToggle.tap()

    XCTAssertTrue(
      waitUntil {
        guard let restoredSidebar = sidebarShellQuery.allElementsBoundByIndex.first else {
          return false
        }
        return restoredSidebar.frame.width > (initialSidebarWidth * 0.75)
      }
    )
    XCTAssertTrue(refreshButton.isHittable)
    refreshButton.tap()
    XCTAssertTrue(refreshButton.exists)
  }

  func testSidebarFilterMenuHidesWhenSidebarIsCollapsed() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    let sidebarToggle = sidebarToggleButton(in: app)
    let sidebarShellQuery = app.otherElements
      .matching(identifier: Accessibility.sidebarShellFrame)
    let sidebarShell = sidebarShellQuery.firstMatch
    let searchState = element(in: app, identifier: Accessibility.sidebarSearchState)
    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)

    XCTAssertTrue(sidebarToggle.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(searchState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      sidebarFilterControl(in: app)
        .waitForExistence(timeout: Self.actionTimeout)
    )
    XCTAssertTrue(sidebarShell.waitForExistence(timeout: Self.actionTimeout))
    let initialSidebarWidth = sidebarShell.frame.width
    XCTAssertGreaterThan(initialSidebarWidth, 200)

    sidebarToggle.tap()

    XCTAssertTrue(
      waitUntil {
        guard let collapsedSidebar = sidebarShellQuery.allElementsBoundByIndex.first else {
          return true
        }
        return collapsedSidebar.frame.width < max(120, initialSidebarWidth * 0.5)
      }
    )
    XCTAssertTrue(
      waitUntil {
        !self.sidebarFilterControl(in: app).exists
      },
      "Sidebar-only filter controls should leave the toolbar when the sidebar is collapsed"
    )

    sidebarToggle.tap()

    XCTAssertTrue(
      waitUntil {
        guard let restoredSidebar = sidebarShellQuery.allElementsBoundByIndex.first else {
          return false
        }
        return restoredSidebar.frame.width > (initialSidebarWidth * 0.75)
      }
    )
    XCTAssertTrue(
      waitUntil {
        let filterMenu = self.sidebarFilterControl(in: app)
        return searchState.label.contains("visible=true")
          && filterMenu.exists
          && !filterMenu.frame.isEmpty
      },
      """
      Sidebar filter controls should return when the sidebar is visible again.
      searchState=\(searchState.label)
      searchFieldFrame=\(searchField.frame)
      sidebarShellFrame=\(sidebarShell.frame)
      filterDiagnostics=\(sidebarFilterControlDiagnostics(in: app))
      """
    )
  }

}
