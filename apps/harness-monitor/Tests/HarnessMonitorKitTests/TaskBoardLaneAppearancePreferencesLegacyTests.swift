import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board lane appearance preference migrations")
@MainActor
struct TaskBoardLaneAppearancePreferencesLegacyTests {
  @Test("Legacy Backlog override loads as Inbox and writes canonically")
  func legacyBacklogOverrideLoadsAsInboxAndWritesCanonically() {
    let legacyRawValue = #"{"backlog":{"colorToken":"purple","symbolName":"archivebox"}}"#

    let overrides = TaskBoardLaneAppearancePreferences.overrides(from: legacyRawValue)
    let canonicalRawValue = TaskBoardLaneAppearancePreferences.rawValue(for: overrides)

    #expect(overrides[.inbox]?.colorToken == .purple)
    #expect(overrides[.inbox]?.symbolName == "archivebox")
    #expect(canonicalRawValue.contains(#""inbox""#))
    #expect(!canonicalRawValue.contains("backlog"))
  }
}
