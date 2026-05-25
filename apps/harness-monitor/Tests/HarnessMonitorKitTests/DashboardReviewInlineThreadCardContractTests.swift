import Foundation
import Testing

/// Source contract for the inline conversation card view. The card binds
/// async resolve/reply ports and renders comment bodies + avatars; the wiring
/// is pinned here the way the rest of the Reviews view tree is (see
/// ``AppOpenAnythingSourceContractTests``). Live interaction is exercised by
/// the Phase 8 launch verification.
@Suite("Dashboard review inline thread card contracts")
struct DashboardReviewInlineThreadCardContractTests {
  @Test("inline thread card renders comments and binds resolve/reply ports")
  func inlineThreadCardRendersAndBindsPorts() throws {
    let source = try previewableSourceFile(
      named: "Views/Dashboard/DashboardReviewInlineThreadCard.swift"
    )

    // Stable container id so the diff host and UI tests can find the card.
    #expect(source.contains("dashboardReviewInlineThreadCard"))
    // Comment bodies render through the shared markdown view + avatars through
    // the cache-backed loader, and timestamps reuse the shared formatter.
    #expect(source.contains("HarnessMonitorMarkdownText("))
    #expect(source.contains("AvatarImageView("))
    #expect(source.contains("formatRelativeUpdatedAt("))
    // Resolve + reply route through the injected async ports (POD-first, no
    // direct store reference) so the card stays previewable and testable.
    #expect(source.contains("onResolveToggle("))
    #expect(source.contains("onReply("))
    #expect(source.contains("dashboardReviewInlineThreadResolveButton"))
    #expect(source.contains("dashboardReviewInlineThreadReplyField"))
    // Per-card collapse is local state seeded from the thread.
    #expect(source.contains("isCollapsed"))
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
