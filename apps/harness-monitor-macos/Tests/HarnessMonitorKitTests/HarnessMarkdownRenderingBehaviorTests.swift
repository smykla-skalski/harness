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

  @Test("Markdown markers share one compact marker lane")
  func markdownMarkersShareOneCompactMarkerLane() throws {
    let paragraphSource = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMarkdownParagraphView.swift"
    )
    let textSource = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMonitorMarkdownText.swift"
    )

    #expect(paragraphSource.contains("HarnessMarkdownMarkerMetrics(style: style)"))
    #expect(paragraphSource.contains(".frame(width: metrics.columnWidth, alignment: .center)"))
    #expect(textSource.contains(".frame(width: metrics.columnWidth"))
    #expect(textSource.contains("metrics.firstLineCenterBaselineOffset"))
  }

  @Test("Markdown table renderer keeps content-width columns")
  func markdownTableRendererKeepsContentWidthColumns() throws {
    let source = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMarkdownTableView.swift"
    )

    #expect(source.contains("ViewThatFits(in: .horizontal)"))
    #expect(source.contains("HarnessMarkdownTableLayout"))
    #expect(source.contains("spareWidth / CGFloat(columnCount)"))
    #expect(source.contains("measurement.rowHeights[row] - size.height"))
    #expect(!source.contains("GridRow"))
  }

  @Test("Markdown links expose hover and pointer affordances")
  func markdownLinksExposeHoverAndPointerAffordances() throws {
    let source = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMarkdownInlineFlowView.swift"
    )

    #expect(source.contains("HarnessMarkdownLinkHoverModifier"))
    #expect(source.contains("NSCursor.pointingHand.push()"))
    #expect(source.contains("HarnessMarkdownInlineWrapLayout(horizontalSpacing: 0"))
    #expect(!source.contains(".padding(.horizontal"))
  }

  @Test("Markdown inline renderer decodes HTML entities")
  func markdownInlineRendererDecodesHTMLEntities() {
    let rendered = HarnessMarkdownInlineRenderer.attributedString(
      from: [
        .text("#&#8203;376 "),
        .link(
          label: [.text("@&#8203;actions/core")],
          destination: "https://example.com?a=1&amp;b=2",
          title: nil,
        ),
      ],
      font: .body
    )

    #expect(String(rendered.characters) == "#\u{200B}376 @\u{200B}actions/core")
  }

  @Test("Task checkboxes use native checkbox controls")
  func taskCheckboxesUseNativeCheckboxControls() throws {
    let source = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMonitorMarkdownText.swift"
    )

    #expect(source.contains("Toggle(isOn: .constant(checkbox))"))
    #expect(source.contains(".toggleStyle(.checkbox)"))
    #expect(source.contains(".frame(width: metrics.columnWidth, height: metrics.firstLineHeight"))
    #expect(source.contains("metrics.firstLineCenterBaselineOffset"))
  }

  @Test("Markdown details summary row toggles disclosure")
  func markdownDetailsSummaryRowTogglesDisclosure() throws {
    let source = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMonitorMarkdownText.swift"
    )

    #expect(source.contains("Button {"))
    #expect(source.contains("isExpanded.toggle()"))
    #expect(source.contains(".contentShape(Rectangle())"))
    #expect(source.contains("HarnessMarkdownPointerHoverModifier"))
    #expect(source.contains("metrics.chevronSize"))
    #expect(!source.contains("DisclosureGroup(isExpanded: $isExpanded)"))
  }

  @Test("Markdown renderer suppresses thematic breaks before headings")
  func markdownRendererSuppressesThematicBreaksBeforeHeadings() throws {
    let source = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMonitorMarkdownText.swift"
    )

    #expect(source.contains("isSuppressedThematicBreak"))
    #expect(source.contains("case .thematicBreak = blocks[index]"))
    #expect(source.contains("case .heading = blocks[index + 1]"))
  }

  @Test("Dependency description card omits duplicate title")
  func dependencyDescriptionCardOmitsDuplicateTitle() throws {
    let source = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Dashboard/DashboardDependenciesRouteView.swift"
    )

    #expect(source.contains("detailSection(nil)"))
    #expect(!source.contains("detailSection(\"Description\")"))
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
