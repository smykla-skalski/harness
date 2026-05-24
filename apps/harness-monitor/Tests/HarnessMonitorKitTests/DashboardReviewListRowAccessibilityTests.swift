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

  @Test("row source uses a minimum-height floor for row sizing")
  func rowSourceUsesMinimumHeightFloorForRowSizing() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    // Item 34: row height should follow natural content, with a deterministic
    // min-height floor instead of an ideal-height guess.
    #expect(source.contains(".frame(minHeight: minimumRowHeight"))
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
    #expect(source.contains("Text(pullRequestNumberText)"))
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

  @Test("row minimumHeight grows for each optional strip")
  func rowMinimumHeightGrowsForEachOptionalStrip() {
    let bare = DashboardReviewListRowHeight.minimumHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasWrappedTitle: false,
        hasSecondaryLine: false,
        hasAttentionStrip: false,
        hasRequiredFailedChecks: false,
        hasLabels: false,
        verticalPadding: 10,
        lineSpacing: 4
      ))
    let withAttention = DashboardReviewListRowHeight.minimumHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasWrappedTitle: false,
        hasSecondaryLine: false,
        hasAttentionStrip: true,
        hasRequiredFailedChecks: false,
        hasLabels: false,
        verticalPadding: 10,
        lineSpacing: 4
      ))
    let withAttentionAndLabels = DashboardReviewListRowHeight.minimumHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasWrappedTitle: false,
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

  @Test("row minimumHeight is identical for the same content shape")
  func rowMinimumHeightIsIdenticalForTheSameContentShape() {
    let first = DashboardReviewListRowHeight.minimumHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasWrappedTitle: false,
        hasSecondaryLine: true,
        hasAttentionStrip: true,
        hasRequiredFailedChecks: true,
        hasLabels: true,
        verticalPadding: 10,
        lineSpacing: 4
      ))
    let second = DashboardReviewListRowHeight.minimumHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasWrappedTitle: false,
        hasSecondaryLine: true,
        hasAttentionStrip: true,
        hasRequiredFailedChecks: true,
        hasLabels: true,
        verticalPadding: 10,
        lineSpacing: 4
      ))
    #expect(first == second)
  }

  @Test("row minimumHeight allocates an extra title line when the title wraps")
  func rowMinimumHeightAllocatesExtraTitleLineWhenWrapped() {
    let layout: (Bool) -> DashboardReviewListRowHeight.Layout = { wrapped in
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: 18,
        captionLineHeight: 14,
        pillStripHeight: 22,
        hasWrappedTitle: wrapped,
        hasSecondaryLine: false,
        hasAttentionStrip: false,
        hasRequiredFailedChecks: false,
        hasLabels: false,
        verticalPadding: 10,
        lineSpacing: 4
      )
    }
    let short = DashboardReviewListRowHeight.minimumHeight(layout(false))
    let wrapped = DashboardReviewListRowHeight.minimumHeight(layout(true))
    // Wrapped allocates exactly one extra titleLineHeight; pill + caption +
    // padding terms are identical, so the delta must be 18.
    #expect(wrapped - short == 18)
  }

  @Test("titleLikelyWraps only reserves extra baseline height for explicit newlines")
  func titleLikelyWrapsOnlyReservesExtraBaselineHeightForExplicitNewlines() {
    #expect(DashboardReviewListRowHeight.titleLikelyWraps("Short title") == false)
    #expect(DashboardReviewListRowHeight.titleLikelyWraps("First\nSecond") == true)
    let longTitle = "ci(deps): update golangci/golangci-lint-action to v6.5.0"
    #expect(DashboardReviewListRowHeight.titleLikelyWraps(longTitle) == false)
  }

  @Test("estimatedTitleLineCount respects only explicit lines and the configured cap")
  func estimatedTitleLineCountRespectsOnlyExplicitLinesAndTheConfiguredTitleCap() {
    let longTitle =
      "ci(deps): update golangci/golangci-lint-action to v6.5.0 and align the reusable workflow inputs"
    #expect(DashboardReviewListRowHeight.estimatedTitleLineCount(longTitle, maximumLines: 1) == 1)
    #expect(DashboardReviewListRowHeight.estimatedTitleLineCount(longTitle, maximumLines: 2) == 1)
    #expect(
      DashboardReviewListRowHeight.estimatedTitleLineCount(
        "First\nSecond\nThird",
        maximumLines: 2
      ) == 2
    )
  }

  @Test("displayed title strips supported semantic prefixes only when enabled")
  func displayedTitleStripsSupportedSemanticPrefixesOnlyWhenEnabled() {
    #expect(
      dashboardReviewDisplayedTitle(
        "fix: trim whitespace from cache key",
        hidesSemanticPrefix: true
      ) == "trim whitespace from cache key"
    )
    #expect(
      dashboardReviewDisplayedTitle(
        "docs(MADR): added policy matching",
        hidesSemanticPrefix: true
      ) == "added policy matching"
    )
    #expect(
      dashboardReviewDisplayedTitle(
        "feat(api)!: remove deprecated endpoint",
        hidesSemanticPrefix: true
      ) == "remove deprecated endpoint"
    )
    #expect(
      dashboardReviewDisplayedTitle(
        "release: cut 1.2.3",
        hidesSemanticPrefix: true
      ) == "release: cut 1.2.3"
    )
    #expect(
      dashboardReviewDisplayedTitle(
        "fix(scope): ",
        hidesSemanticPrefix: true
      ) == "fix(scope): "
    )
    #expect(
      dashboardReviewDisplayedTitle(
        "fix: trim whitespace from cache key",
        hidesSemanticPrefix: false
      ) == "fix: trim whitespace from cache key"
    )
  }

  @Test("row source lets wrapped titles expand vertically")
  func rowSourceLetsWrappedTitlesExpandVertically() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    #expect(source.contains(".fixedSize(horizontal: false, vertical: true)"))
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

  @Test("labels strip stores repository labels for per-name colour lookup")
  func labelsStripStoresRepositoryLabelsForColourLookup() {
    let descriptors = [
      ReviewRepositoryLabel(name: "bug", color: "d73a4a", description: "Something is broken"),
      ReviewRepositoryLabel(name: "enhancement", color: "a2eeef", description: nil),
    ]
    let strip = DashboardReviewListRowLabelsStrip(
      labels: ["bug", "enhancement", "missing-descriptor"],
      repositoryLabels: descriptors
    )
    #expect(strip.repositoryLabels.count == 2)
    #expect(strip.repositoryLabels.first?.color == "d73a4a")
    // Default empty matches the existing call sites that haven't been wired
    // to plumb the palette yet.
    let bare = DashboardReviewListRowLabelsStrip(labels: ["wip"])
    #expect(bare.repositoryLabels.isEmpty)
  }

  @Test("route view passes per-repository labels into each row")
  func routeViewPassesPerRepositoryLabelsIntoEachRow() throws {
    let source = try rowSource(named: "DashboardReviewsRouteView+Content.swift")
    // Each row receives the palette for its own repository so colour swatches
    // line up with the GitHub label colours instead of all going neutral.
    #expect(
      source.contains("repositoryLabels: routeResponse.repositoryLabels[item.repository] ?? []")
    )
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
