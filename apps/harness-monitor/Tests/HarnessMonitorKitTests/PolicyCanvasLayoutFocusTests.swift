import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas layout focus")
@MainActor
struct PolicyCanvasLayoutFocusTests {
  @Test("dispatcher perform method is a no-op until bound")
  func dispatcherIsInertWhenUnbound() {
    let dispatcher = PolicyCanvasLayoutFocusDispatcher()
    dispatcher.performReflowLayout()
  }

  @Test("reflow dispatches to the bound closure")
  func reflowDispatches() {
    let dispatcher = PolicyCanvasLayoutFocusDispatcher()
    var invocationCount = 0
    dispatcher.reflowLayout = {
      invocationCount += 1
    }

    dispatcher.performReflowLayout()

    #expect(invocationCount == 1)
  }

  @Test("focus equality tracks availability and dispatcher identity")
  func focusEqualityTracksAvailabilityAndIdentity() {
    let dispatcher = PolicyCanvasLayoutFocusDispatcher()
    let focusA = PolicyCanvasLayoutFocus(canReflow: true, dispatcher: dispatcher)
    let focusB = PolicyCanvasLayoutFocus(canReflow: true, dispatcher: dispatcher)
    let focusC = PolicyCanvasLayoutFocus(canReflow: false, dispatcher: dispatcher)
    let otherDispatcher = PolicyCanvasLayoutFocusDispatcher()
    let focusD = PolicyCanvasLayoutFocus(canReflow: true, dispatcher: otherDispatcher)

    #expect(focusA == focusB)
    #expect(focusA != focusC)
    #expect(focusA != focusD)
  }

  @Test("viewport publishes layout focus and app commands consume it")
  func viewportPublishesLayoutFocusAndAppCommandsConsumeIt() throws {
    let viewportSource = try previewableSource(
      "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift"
    )
    #expect(viewportSource.contains(".harnessFocusedSceneValue("))
    #expect(viewportSource.contains("\\.harnessPolicyCanvasLayoutFocus"))
    #expect(viewportSource.contains("sceneFocusEnabled ? layoutFocus : nil"))

    let commandsSource = try harnessSource("App/HarnessMonitorAppCommands.swift")
    #expect(commandsSource.contains("@FocusedValue(\\.harnessPolicyCanvasLayoutFocus)"))
    #expect(commandsSource.contains("performReflowLayout()"))
    #expect(commandsSource.contains("Button(\"Reformat Canvas\")"))
    #expect(commandsSource.contains(".keyboardShortcut(\"l\", modifiers: [.command, .shift])"))
  }

  private func previewableSource(_ relativePath: String) throws -> String {
    try String(
      contentsOf: appRoot.appendingPathComponent("Sources/HarnessMonitorUIPreviewable/\(relativePath)"),
      encoding: .utf8
    )
  }

  private func harnessSource(_ relativePath: String) throws -> String {
    try String(
      contentsOf: appRoot.appendingPathComponent("Sources/HarnessMonitor/\(relativePath)"),
      encoding: .utf8
    )
  }

  private var appRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
