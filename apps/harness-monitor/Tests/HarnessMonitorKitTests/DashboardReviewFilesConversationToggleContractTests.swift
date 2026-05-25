import Foundation
import Testing

/// Source contract for the in-view conversation-visibility toggle and the
/// ⌘⌥⇧C Reviews-menu command gated to Files mode. The focused-value plumbing
/// is scene-level SwiftUI; live behavior is exercised by Phase 8.
@Suite("Dashboard review files conversation toggle contracts")
struct DashboardReviewFilesConversationToggleContractTests {
  @Test("Files mode publishes a per-session visibility override and toggle")
  func detailPanePublishesOverrideAndToggle() throws {
    let pane = try previewable(named: "Views/Dashboard/DashboardReviewFilesModeDetailPane.swift")
    #expect(pane.contains("@State private var conversationVisibilityOverride"))
    #expect(pane.contains("conversationVisibilityOverride ?? preferences.snapshot.filesConversationVisibility"))
    #expect(pane.contains("func cycleConversationVisibility()"))
    #expect(pane.contains("conversationVisibilityToggle"))
    #expect(pane.contains("\\.dashboardReviewFilesConversationCommand"))

    let conversation = try previewable(
      named: "Views/Dashboard/DashboardReviewFilesModeDetailPane+Conversation.swift"
    )
    #expect(conversation.contains("var conversationVisibilityToggle"))
    #expect(conversation.contains("dashboardReviewFilesConversationVisibilityToggle"))
    #expect(conversation.contains("cycleConversationVisibility"))
    // The context uses the effective (override-aware) visibility, not the raw pref.
    #expect(conversation.contains("visibility: effectiveConversationVisibility"))
  }

  @Test("the focused command exposes a title + cycle and is an environment value")
  func focusedCommandShape() throws {
    let command = try previewable(
      named: "Views/Dashboard/DashboardReviewFilesConversationCommand.swift"
    )
    #expect(command.contains("public struct DashboardReviewFilesConversationCommand"))
    #expect(command.contains("public let cycle: () -> Void"))
    #expect(command.contains("@Entry public var dashboardReviewFilesConversationCommand"))
  }

  @Test("the Reviews menu binds Cycle Inline Conversations to Cmd-Opt-Shift-C")
  func reviewsMenuBindsCycleCommand() throws {
    let menu = try harness(named: "Commands/ReviewCommands.swift")
    #expect(menu.contains("@FocusedValue(\\.dashboardReviewFilesConversationCommand)"))
    #expect(menu.contains("filesConversationCommand?.cycle()"))
    #expect(menu.contains(".keyboardShortcut(\"c\", modifiers: [.command, .option, .shift])"))
    // Disabled outside Files mode (focused value absent).
    #expect(menu.contains(".disabled(filesConversationCommand == nil)"))
  }

  private func previewable(named relativePath: String) throws -> String {
    try String(
      contentsOf: targetRoot("HarnessMonitorUIPreviewable").appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }

  private func harness(named relativePath: String) throws -> String {
    try String(
      contentsOf: targetRoot("HarnessMonitor").appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }

  private func targetRoot(_ target: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources")
      .appendingPathComponent(target)
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
