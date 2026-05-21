import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Harness markdown rendering behavior")
struct HarnessMarkdownRenderingBehaviorTests {
  @Test("Leading emoji text splits into a stable marker column")
  func leadingEmojiTextSplitsIntoStableMarkerColumn() {
    let split = HarnessMarkdownLeadingEmoji(
      inlines: [.text("🚦 "), .strong([.text("Automerge")]), .text(": Disabled")]
    )

    #expect(split?.emoji == "🚦")
    #expect(split?.remaining == [.strong([.text("Automerge")]), .text(": Disabled")])
  }

  @Test("Markdown table renderer keeps content-width columns")
  func markdownTableRendererKeepsContentWidthColumns() throws {
    let source = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMonitorMarkdownText.swift"
    )

    #expect(source.contains("ScrollView(.horizontal)"))
    #expect(source.contains("GridRow(alignment: .center)"))
    #expect(!source.contains(".frame(maxWidth: .infinity, alignment: swiftAlignment"))
  }

  @Test("Markdown links expose hover and pointer affordances")
  func markdownLinksExposeHoverAndPointerAffordances() throws {
    let source = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMarkdownInlineFlowView.swift"
    )

    #expect(source.contains("HarnessMarkdownLinkHoverModifier"))
    #expect(source.contains("NSCursor.pointingHand.push()"))
  }

  private func readRepositoryFile(_ relativePath: String) throws -> String {
    try String(contentsOfFile: repositoryPath(relativePath), encoding: .utf8)
  }

  private func repositoryPath(_ relativePath: String) -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(relativePath)
      .path
  }
}
