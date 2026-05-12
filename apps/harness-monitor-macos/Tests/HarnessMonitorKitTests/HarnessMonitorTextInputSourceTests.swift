import Foundation
import Testing

@Suite("Harness Monitor text input sources")
struct HarnessMonitorTextInputSourceTests {
  @Test("Previewable target does not depend on SwiftUI Introspect")
  func previewableTargetDoesNotDependOnSwiftUIIntrospect() throws {
    let packageSource = try repoFile(at: "apps/harness-monitor-macos/Tuist/Package.swift")
    let projectSource = try repoFile(at: "apps/harness-monitor-macos/Project.swift")

    #expect(!packageSource.contains("https://github.com/siteline/swiftui-introspect"))
    #expect(!packageSource.contains("\"SwiftUIIntrospect\": .framework"))
    #expect(!projectSource.contains(".external(name: \"SwiftUIIntrospect\")"))
  }

  @Test("Shared text input helpers keep multiline ownership without Introspect")
  func sharedTextInputHelpersKeepMultilineOwnershipWithoutIntrospect() throws {
    let themeSource = try previewableSourceFile(at: "Theme/HarnessMonitorTextSize.swift")
    let multilineSource = try previewableSourceFile(
      at: "Views/Shared/HarnessMonitorMultilineTextField.swift")

    #expect(!themeSource.contains("import SwiftUIIntrospect"))
    #expect(!themeSource.contains("HarnessMonitorNativeVerticalTextFieldConfiguration"))
    #expect(!themeSource.contains(".introspect("))
    #expect(!themeSource.contains("public func harnessNativeVerticalTextField() -> some View"))

    #expect(multilineSource.contains("private let maxHeightOverride: CGFloat?"))
    #expect(multilineSource.contains("private let showsChrome: Bool"))
    #expect(multilineSource.contains("maxHeight: CGFloat? = nil"))
    #expect(multilineSource.contains("showsChrome: Bool = true"))
    #expect(multilineSource.contains("HarnessMonitorMultilineChromeModifier"))
    #expect(multilineSource.contains("HarnessMonitorMultilineScrollView"))
    #expect(multilineSource.contains("override func hitTest(_ point: NSPoint) -> NSView?"))
    #expect(multilineSource.contains("return textView"))
  }

  @Test("Shared text input helpers are used across migrated surfaces")
  func sharedTextInputHelpersAreUsedAcrossMigratedSurfaces() throws {
    let newSessionSource = try previewableSourceFile(
      at: "Views/NewSession/NewSessionSheetView.swift")
    let composerSource = try previewableSourceFile(at: "Views/Sessions/SessionAgentComposer.swift")
    let codexRunSource = try previewableSourceFile(
      at: "Views/Sessions/SessionCodexRunDetailSection.swift")
    let sendSignalSource = try previewableSourceFile(at: "Views/Signals/SendSignalSheetView.swift")
    let agentDetailSource = try previewableSourceFile(
      at: "Views/Agents/AgentDetailSendUpdateSection.swift")
    let leaderTransferSource = try previewableSourceFile(
      at: "Views/Actions/LeaderTransferSheet.swift")
    let createTaskSource = try previewableSourceFile(at: "Views/Actions/CreateTaskSheet.swift")
    let taskActionsSource = try previewableSourceFile(at: "Views/Actions/TaskActionsSheet.swift")
    let notificationsSource = try previewableSourceFile(
      at: "Views/Settings/SettingsNotificationsSection.swift")

    #expect(newSessionSource.contains("HarnessMonitorMultilineTextField("))
    #expect(!newSessionSource.contains("TextEditor(text: $viewModel.context)"))

    #expect(composerSource.contains("HarnessMonitorMultilineTextField("))
    #expect(!composerSource.contains("TextEditor(text: $message)"))
    #expect(!composerSource.contains("showsChrome: false"))

    #expect(codexRunSource.contains("HarnessMonitorMultilineTextField<Never>("))
    #expect(!codexRunSource.contains("TextEditor(text: $contextDraft)"))
    #expect(!codexRunSource.contains("showsChrome: false"))
    #expect(!codexRunSource.contains(".padding(.horizontal, 4)"))
    #expect(!codexRunSource.contains(".padding(.vertical, 4)"))
    #expect(!codexRunSource.contains(".quaternary.opacity(0.2)"))

    for source in [
      sendSignalSource,
      agentDetailSource,
      leaderTransferSource,
      createTaskSource,
      taskActionsSource,
      notificationsSource,
    ] {
      #expect(source.contains("axis: .vertical"))
      #expect(!source.contains(".harnessNativeVerticalTextField()"))
    }
  }

  private func previewableSourceFile(at relativePath: String) throws -> String {
    try repoFile(
      at: "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/\(relativePath)")
  }

  private func repoFile(at relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL = repoRoot.appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
