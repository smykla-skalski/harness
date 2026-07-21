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
    let sessionRowIdentifier = Accessibility.sessionRow(Accessibility.previewSessionID)
    let sessionRow = sessionTrigger(in: app, identifier: sessionRowIdentifier)
    let clearSearchHistoryButton = element(
      in: app,
      identifier: Accessibility.sidebarClearSearchHistoryButton
    )

    XCTAssertTrue(persistenceBanner.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(clearSearchHistoryButton.exists)

    tapSession(in: app, identifier: sessionRowIdentifier)
    tapButton(in: app, identifier: Accessibility.taskUICard)

    let notesUnavailable = element(in: app, identifier: Accessibility.sessionTaskNotesUnavailable)
    XCTAssertTrue(notesUnavailable.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(element(in: app, identifier: Accessibility.sessionTaskNoteField).exists)
    XCTAssertFalse(element(in: app, identifier: Accessibility.sessionTaskNoteAddButton).exists)
  }

  func testObserveSummaryIsAvailableInSessionCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let tasks = app.staticTexts["Tasks"]
    XCTAssertTrue(tasks.waitForExistence(timeout: Self.actionTimeout))

    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.actionTimeout))
    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    XCTAssertTrue(tasks.exists)
  }

  func testEmptyCockpitShowsSharedEmptyStateRowsAcrossAllSections() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "empty-cockpit"]
    )

    let tasksEmpty = element(in: app, identifier: Accessibility.sessionEmptyState("tasks"))
    let agentsEmpty = element(in: app, identifier: Accessibility.sessionEmptyState("agents"))
    let timelineEmpty = element(in: app, identifier: Accessibility.sessionEmptyState("timeline"))

    XCTAssertTrue(tasksEmpty.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(agentsEmpty.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(timelineEmpty.waitForExistence(timeout: Self.actionTimeout))

    XCTAssertEqual(tasksEmpty.label, "No tasks right now")
    XCTAssertEqual(agentsEmpty.label, "No agents yet. Join a leader to activate this session")
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

  func testTaskBoardBoardOnlyItemSelectsThenDoubleClickOpensManagementSheet() throws {
    let itemID = "preview-board-only"
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "task-board-board-only"
      ]
    )

    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let boardItem = button(in: app, identifier: "harness.task-board.api-item.\(itemID)")
    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(boardItem.waitForExistence(timeout: Self.actionTimeout))

    let managementPanel = element(
      in: app,
      identifier: "harness.task-board.manage-item.\(itemID)"
    )

    boardItem.click()
    XCTAssertEqual(boardItem.value as? String, "Selected")
    XCTAssertFalse(managementPanel.exists)

    boardItem.doubleClick()
    XCTAssertTrue(managementPanel.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["Manage Board Item"].exists)
    XCTAssertTrue(app.textFields["Title"].exists)
    XCTAssertFalse(app.staticTexts["Task Not Available"].exists)

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !managementPanel.exists },
      "Manage Board Item should dismiss with Escape when presented as a sheet."
    )
  }

  func testTaskBoardCreatingItemDismissesTheManagementSheet() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "task-board-board-only"
      ]
    )

    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.actionTimeout))

    tapButton(in: app, identifier: "harness.task-board.new-item")

    let managementPanel = element(in: app, identifier: "harness.task-board.manage-item.new")
    XCTAssertTrue(managementPanel.waitForExistence(timeout: Self.actionTimeout))

    let titleField = app.textFields["Title"].firstMatch
    XCTAssertTrue(titleField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: titleField))
    titleField.typeText("Duplicate-guard verification item")

    let createButton = button(in: app, identifier: "harness.task-board.manage-item.submit")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { createButton.isEnabled },
      "Create Item should enable once the title is filled in"
    )

    tapButton(in: app, identifier: "harness.task-board.manage-item.submit")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !managementPanel.exists },
      "Create Board Item should dismiss the sheet after creating the item, "
        + "otherwise a second press on Create Item duplicates it."
    )
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
