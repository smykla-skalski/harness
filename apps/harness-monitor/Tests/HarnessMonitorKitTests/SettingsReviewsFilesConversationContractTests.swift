import Foundation
import Testing

/// Source contract for the Reviews > Files conversation-visibility default
/// picker. The picker binding lives in a private SwiftUI computed property, so
/// the wiring is pinned here the same way the rest of the Settings controls are
/// (see ``AppOpenAnythingSourceContractTests``); the live interaction is
/// exercised by the in-view control and the Phase 8 launch verification.
@Suite("Settings Reviews Files conversation visibility contracts")
struct SettingsReviewsFilesConversationContractTests {
  @Test("Files settings mount a conversation-visibility picker bound to the preference")
  func filesSettingsExposeConversationVisibilityPicker() throws {
    let source = try previewableSourceFile(
      named: "Views/Settings/SettingsReviewsFilesSection.swift"
    )

    // The picker mounts in the Files disclosure body right after the layout
    // picker so the two default-layout controls sit together.
    #expect(source.contains("filesLayoutPicker"))
    #expect(source.contains("conversationVisibilityPicker"))
    // It offers every visibility case, each labelled with its menu title.
    #expect(source.contains("ForEach(ConversationVisibility.allCases"))
    #expect(source.contains("visibility.menuTitle"))
    #expect(source.contains(".pickerStyle(.menu)"))
    // Selection round-trips through the persisted raw preference - reads the
    // typed accessor, writes the raw string the codec stores.
    #expect(source.contains("draft.filesConversationVisibility"))
    #expect(source.contains("draft.filesConversationVisibilityRaw = $0.rawValue"))
    // Stable accessibility id for UI tests and parity with the in-view control.
    #expect(source.contains("settingsReviewFilesConversationVisibilityPicker"))
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: previewableSourceURL(named: relativePath), encoding: .utf8)
  }

  private func previewableSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
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
