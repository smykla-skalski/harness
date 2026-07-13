import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board selection focus")
struct TaskBoardSelectionFocusTests {
  @Test("Equivalent values retain dispatcher identity")
  func equivalentValuesRetainDispatcherIdentity() {
    let dispatcher = TaskBoardSelectionDispatcher()
    let first = TaskBoardSelectionFocus(
      selectionCount: 2,
      canDelete: true,
      dispatcher: dispatcher
    )
    let second = TaskBoardSelectionFocus(
      selectionCount: 2,
      canDelete: true,
      dispatcher: dispatcher
    )

    #expect(first == second)
  }

  @Test("Different dispatcher references are not equivalent")
  func differentDispatcherReferencesAreNotEquivalent() {
    let first = TaskBoardSelectionFocus(
      selectionCount: 1,
      canDelete: true,
      dispatcher: TaskBoardSelectionDispatcher()
    )
    let second = TaskBoardSelectionFocus(
      selectionCount: 1,
      canDelete: true,
      dispatcher: TaskBoardSelectionDispatcher()
    )

    #expect(first != second)
  }

  @Test("Delete forwards only while enabled")
  func deleteForwardsOnlyWhileEnabled() {
    let dispatcher = TaskBoardSelectionDispatcher()

    TaskBoardSelectionFocus(
      selectionCount: 0,
      canDelete: false,
      dispatcher: dispatcher
    ).performDeleteSelection()
    TaskBoardSelectionFocus(
      selectionCount: 3,
      canDelete: true,
      dispatcher: dispatcher
    ).performDeleteSelection()

    #expect(dispatcher.deleteRequestGeneration == 1)
  }

  @Test("Inspector toggle forwards through a stable dispatcher")
  func inspectorToggleForwardsThroughStableDispatcher() {
    let dispatcher = TaskBoardOperationsInspectorFocusDispatcher()
    var toggleCount = 0
    dispatcher.toggleInspector = {
      toggleCount += 1
    }
    let first = TaskBoardOperationsInspectorFocus(
      isVisible: false,
      canToggle: true,
      dispatcher: dispatcher
    )
    let second = TaskBoardOperationsInspectorFocus(
      isVisible: false,
      canToggle: true,
      dispatcher: dispatcher
    )

    first.dispatcher.performToggleInspector()

    #expect(toggleCount == 1)
    #expect(first == second)
    #expect(
      first
        != TaskBoardOperationsInspectorFocus(
          isVisible: true,
          canToggle: true,
          dispatcher: dispatcher
        )
    )
  }

  @Test("Task board command owns Delete whenever its focus is mounted")
  func taskBoardCommandOwnsDeleteWheneverMounted() throws {
    let commandsSource = try sourceFile(
      at: "Sources/HarnessMonitor/App/HarnessMonitorAppCommands.swift"
    )
    let focusSource = try sourceFile(
      at: "Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardSelectionFocus.swift"
    )
    let overviewSource = try sourceFile(
      at: "Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardOverviewView.swift"
    )
    let overviewFocusSource = try sourceFile(
      at:
        "Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardOverviewView+SelectionFocus.swift"
    )

    #expect(commandsSource.contains("@FocusedValue(\\.harnessTaskBoardCommandFocus)"))
    #expect(commandsSource.contains("taskBoardCommandFocus?.selection"))
    #expect(commandsSource.contains("if let taskBoardSelectionFocus"))
    #expect(commandsSource.contains("return taskBoardSelectionFocus.canDelete"))
    #expect(commandsSource.contains("taskBoardSelectionFocus.performDeleteSelection()"))
    #expect(commandsSource.contains(".keyboardShortcut(.delete, modifiers: [])"))
    #expect(!commandsSource.contains(".keyboardShortcut(.deleteForward"))
    #expect(focusSource.contains(".keyboardShortcut(.deleteForward, modifiers: [])"))
    #expect(focusSource.contains("@Observable"))
    #expect(focusSource.contains("deleteRequestGeneration &+= 1"))
    #expect(!focusSource.contains("deleteSelection: (() -> Void)?"))
    #expect(focusSource.contains(".opacity(0)"))
    #expect(focusSource.contains(".accessibilityHidden(true)"))
    #expect(focusSource.contains("public struct TaskBoardCommandFocus: Equatable"))
    #expect(
      focusSource.contains(
        "public let operationsInspector: TaskBoardOperationsInspectorFocus?"
      )
    )
    #expect(
      focusSource.contains(
        "@Entry public var harnessTaskBoardCommandFocus: TaskBoardCommandFocus?"
      )
    )
    #expect(
      overviewSource.contains(
        ".harnessFocusedSceneValue(\\.harnessTaskBoardCommandFocus, taskBoardCommandFocus)"
      )
    )
    #expect(
      overviewSource.contains(
        ".taskBoardSelectionForwardDeleteShortcut(taskBoardCommandFocus?.selection)"
      )
    )
    #expect(overviewFocusSource.contains("guard isCommandFocusActive else { return nil }"))
    #expect(overviewFocusSource.contains("operationsInspector: operationsInspectorFocus"))
    #expect(
      overviewSource.contains(
        ".onChange(of: taskBoardSelectionDispatcher.deleteRequestGeneration)"
      )
    )
    #expect(!overviewSource.contains("bindTaskBoardSelectionDispatcher"))
  }

  private func sourceFile(at relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let monitorRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: monitorRoot.appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }
}
