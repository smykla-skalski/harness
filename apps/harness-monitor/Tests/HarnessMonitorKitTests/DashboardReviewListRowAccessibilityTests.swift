import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review list row accessibility and structure")
@MainActor
struct DashboardReviewListRowAccessibilityTests {
  @Test("row source declares contain-not-combine accessibility")
  func rowSourceDeclaresContainNotCombineAccessibility() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    // Items 31 / 67: navigation must be allowed inside the row.
    #expect(source.contains(".accessibilityElement(children: .contain)"))
    #expect(!source.contains(".accessibilityElement(children: .combine)"))
  }

  @Test("row source labels the status icon instead of hiding it")
  func rowSourceLabelsTheStatusIconInsteadOfHidingIt() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    // Items 32 / 67: status icon must carry its own accessibility label.
    #expect(source.contains(".accessibilityLabel(item.statusAccessibilityLabel)"))
    #expect(
      !source.contains(
        "Image(systemName: item.statusSystemImage)\n          .font"
          + "(.system(size: 14, weight: .semibold))\n          .foregroundStyle(item.statusTint)\n"
          + "          .accessibilityHidden(true)"
      )
    )
  }

  @Test("row source attaches help on title and secondary line")
  func rowSourceAttachesHelpOnTitleAndSecondaryLine() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    // Item 30: truncated content must be recoverable on hover.
    #expect(source.contains(".help(item.title)"))
    // Secondary text is optional now (collapsed when the list is grouped by
    // repository); the help attaches against the unwrapped local binding.
    #expect(source.contains(".help(secondary)"))
  }

  @Test("row source dims the status icon when viewer can't update")
  func rowSourceDimsStatusIconWhenViewerCannotUpdate() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    // Item 27: viewerCanUpdate gate is visible in the icon's opacity.
    #expect(source.contains(".opacity(item.viewerCanUpdate ? 1 : 0.4)"))
    #expect(source.contains("You don't have permission to update this PR"))
  }

  @Test("row source uses idealHeight for uniform row height")
  func rowSourceUsesIdealHeightForUniformRowHeight() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    // Item 34: row height must be stable, set via .frame(idealHeight:).
    #expect(source.contains(".frame(idealHeight: rowIdealHeight)"))
    #expect(source.contains("@ScaledMetric"))
  }

  @Test("row source surfaces author chip and labels strip companions")
  func rowSourceSurfacesAuthorChipAndLabelsStripCompanions() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    // Items 24, 25, 26, 28, 29, 72: the row consumes the new companions.
    #expect(source.contains("DashboardReviewListRowAuthorChip("))
    #expect(source.contains("avatarURL: item.authorAvatarURL"))
    #expect(source.contains("DashboardReviewListRowLabelsStrip("))
    #expect(source.contains("DashboardReviewListRowReviewerSummary("))
    #expect(source.contains("DashboardReviewChangePill("))
    #expect(source.contains("DashboardReviewRequiredFailedCheckStrip("))
  }

  @Test("reviewer pills share the avatar cache path")
  func reviewerPillsShareTheAvatarCachePath() throws {
    let source = try rowSource(named: "DashboardReviewsReviewLabelLists.swift")
    #expect(source.contains("AvatarImageView("))
    #expect(!source.contains("AsyncImage("))
    #expect(source.contains("store.reviewAvatarImage("))
  }

  @Test("row source exposes a pinned indicator with a dedicated accessibility label")
  func rowSourceExposesPinnedIndicatorAccessibility() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    #expect(source.contains("dashboardReviewPinnedIndicator(item.pullRequestID)"))
    #expect(source.contains(".accessibilityLabel(\"Pinned pull request\")"))
  }

  @Test("row idealHeight grows for each optional strip")
  func rowIdealHeightGrowsForEachOptionalStrip() {
    let bare = DashboardReviewListRowHeight.idealHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasSecondaryLine: false,
        hasAttentionStrip: false,
        hasRequiredFailedChecks: false,
        hasLabels: false,
        verticalPadding: 10,
        lineSpacing: 4
      ))
    let withAttention = DashboardReviewListRowHeight.idealHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasSecondaryLine: false,
        hasAttentionStrip: true,
        hasRequiredFailedChecks: false,
        hasLabels: false,
        verticalPadding: 10,
        lineSpacing: 4
      ))
    let withAttentionAndLabels = DashboardReviewListRowHeight.idealHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasSecondaryLine: false,
        hasAttentionStrip: true,
        hasRequiredFailedChecks: false,
        hasLabels: true,
        verticalPadding: 10,
        lineSpacing: 4
      ))

    #expect(withAttention > bare)
    #expect(withAttentionAndLabels > withAttention)
  }

  @Test("row idealHeight is identical for the same content shape")
  func rowIdealHeightIsIdenticalForTheSameContentShape() {
    let first = DashboardReviewListRowHeight.idealHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasSecondaryLine: true,
        hasAttentionStrip: true,
        hasRequiredFailedChecks: true,
        hasLabels: true,
        verticalPadding: 10,
        lineSpacing: 4
      ))
    let second = DashboardReviewListRowHeight.idealHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasSecondaryLine: true,
        hasAttentionStrip: true,
        hasRequiredFailedChecks: true,
        hasLabels: true,
        verticalPadding: 10,
        lineSpacing: 4
      ))
    #expect(first == second)
  }

  @Test("labels strip caps visible chips at six and surfaces overflow")
  func labelsStripCapsVisibleChipsAtSixAndSurfacesOverflow() {
    let manyLabels = (1...10).map { "label-\($0)" }
    let strip = DashboardReviewListRowLabelsStrip(labels: manyLabels)
    // The strip itself isn't a snapshot here, but the cap is documented in
    // the file-top comment and exposed via the private cap. Build-time
    // assertion that the source still encodes the cap value:
    let source = try? rowSource(named: "DashboardReviewListRow+Labels.swift")
    #expect(source?.contains("visibleCap = 6") == true)
    // Sanity: labels are passed through unchanged.
    #expect(strip.labels == manyLabels)
  }

  private func rowSource(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/Dashboard"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
