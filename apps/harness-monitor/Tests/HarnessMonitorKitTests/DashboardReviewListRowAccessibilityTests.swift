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
    let source =
      try rowSource(named: "DashboardReviewListRow.swift")
      + "\n"
      + rowSource(named: "DashboardReviewListRow+AttentionIcons.swift")
    // Items 32 / 67: status icon must carry its own accessibility label.
    #expect(source.contains("label: item.statusAccessibilityLabel"))
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
    // The dimmed-opacity ramp moved into the +Chrome companion; union-read it.
    let source =
      try rowSource(named: "DashboardReviewListRow.swift")
      + "\n"
      + rowSource(named: "DashboardReviewListRow+Chrome.swift")
      + "\n"
      + rowSource(named: "DashboardReviewListRow+AttentionIcons.swift")
    // Item 27: viewerCanUpdate gate is visible in the icon's opacity.
    #expect(source.contains("opacity: item.viewerCanUpdate ? 1 : selectedIconDimmedOpacity"))
    #expect(source.contains("usesSelectedBackgroundContrast ? 0.74 : 0.4"))
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
    #expect(source.contains("Text(inlineIdentityAndAge)"))
  }

  @Test("author chip source exposes author association accessibility semantics")
  func authorChipSourceExposesAuthorAssociationAccessibilitySemantics() throws {
    let source = try rowSource(named: "DashboardReviewListRow+AuthorChip.swift")
    #expect(source.contains("let authorAssociation: ReviewAuthorAssociation"))
    #expect(source.contains("authorAssociationAccessibilityLabel"))
    #expect(source.contains(".accessibilityValue(authorAssociationAccessibilityLabel)"))
  }

  @Test("author chip source draws a contributor-role halo around the avatar")
  func authorChipSourceDrawsContributorRoleHalo() throws {
    let source = try rowSource(named: "DashboardReviewListRow+AuthorChip.swift")
    #expect(source.contains("dashboardReviewAuthorHaloStyle("))
    #expect(source.contains(".overlay {"))
    #expect(source.contains("StrokeStyle("))
  }

  @Test("author chip source draws a narrow white separator ring between halo and avatar")
  func authorChipSourceDrawsANarrowWhiteSeparatorRingBetweenHaloAndAvatar() throws {
    let source = try rowSource(named: "DashboardReviewListRow+AuthorChip.swift")
    #expect(source.contains(".stroke(Color.white.opacity(0.96), lineWidth: 1)"))
  }

  @Test("author chip source uses green teammate halos")
  func authorChipSourceUsesGreenTeammateHalos() throws {
    let source = try rowSource(named: "DashboardReviewListRow+AuthorChip.swift")
    #expect(source.contains("case .owner, .member, .collaborator:"))
    #expect(source.contains("HarnessMonitorTheme.success.opacity(0.78)"))
    #expect(source.contains("HarnessMonitorTheme.success.opacity(0.12)"))
  }

  @Test("author halo style keeps the halo slightly tighter around the avatar")
  func authorHaloStyleKeepsTheHaloSlightlyTighterAroundTheAvatar() {
    let coreHalo = dashboardReviewAuthorHaloStyle(
      for: .member,
      usesSelectedBackgroundContrast: false
    )
    let externalHalo = dashboardReviewAuthorHaloStyle(
      for: .contributor,
      usesSelectedBackgroundContrast: false
    )
    let firstTimeHalo = dashboardReviewAuthorHaloStyle(
      for: .firstTimeContributor,
      usesSelectedBackgroundContrast: false
    )

    #expect(coreHalo?.padding == 1.25)
    #expect(externalHalo?.padding == 1.25)
    #expect(firstTimeHalo?.padding == 1.25)
    #expect(coreHalo?.lineWidth == 3.5)
    #expect(externalHalo?.lineWidth == 3.0)
    #expect(firstTimeHalo?.lineWidth == 3.5)
  }

  @Test("row source renders requested-review and attention as subdued metadata icons")
  func rowSourceRendersRequestedReviewAndAttentionAsSubduedMetadataIcons() throws {
    let source = try rowSource(named: "DashboardReviewListRow+AttentionIcons.swift")
    #expect(source.contains("if item.viewerIsRequestedReviewer {"))
    #expect(source.contains("label: \"Needs me\""))
    #expect(source.contains("if let missingApprovalsHelp {"))
    #expect(source.contains("label: \"Missing approvals\""))
    #expect(source.contains("tint: HarnessMonitorTheme.caution"))
    #expect(!source.contains("mutedUntilHovered"))
    #expect(source.contains("label: kind.label"))
  }

  @Test("title row source keeps only the avatar on the leading edge")
  func titleRowSourceKeepsOnlyTheAvatarOnTheLeadingEdge() throws {
    let source =
      try rowSource(named: "DashboardReviewListRow.swift")
      + "\n"
      + rowSource(named: "DashboardReviewListRowHelpers.swift")

    #expect(!source.contains("leadingStatusIndicatorWidth"))
    #expect(
      source.contains(
        "return showsAvatars ? authorChipWidth + HarnessMonitorTheme.spacingSM : 0"
      )
    )
  }

  @Test("row source renders a trailing metadata icon strip")
  func rowSourceRendersATrailingMetadataIconStrip() throws {
    let rowSourceText = try rowSource(named: "DashboardReviewListRow.swift")
    let iconSource = try rowSource(named: "DashboardReviewListRow+AttentionIcons.swift")

    #expect(rowSourceText.contains("DashboardReviewListRowMetadataIconStrip("))
    #expect(rowSourceText.contains("missingApprovalsHelp: missingApprovalsMetadataHelp"))
    #expect(!iconSource.contains("mutedUntilHovered"))
    #expect(iconSource.contains("item.statusSystemImage"))
  }

  @Test("row source gates reviewer count chrome behind the approval-count preference")
  func rowSourceGatesReviewerCountChromeBehindApprovalCountPreference() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")

    #expect(source.contains("let showsApprovalCounts: Bool"))
    #expect(source.contains("showsApprovalCounts: Bool = false"))
    #expect(source.contains("(showsApprovalCounts && reviewerSummary != nil)"))
    #expect(source.contains("guard !showsApprovalCounts else { return nil }"))
  }

  @Test("status icon source shares the same size and frame contract as the metadata icons")
  func statusIconSourceSharesSameSizeAndFrameContractAsMetadataIcons() throws {
    let source = try rowSource(named: "DashboardReviewListRow+AttentionIcons.swift")

    #expect(source.contains("private let metadataIconPointSize: CGFloat = 12"))
    #expect(source.contains("private let metadataIconFrameWidth: CGFloat = 16"))
    #expect(source.contains(".font(.system(size: metadataIconPointSize, weight: .semibold))"))
    #expect(source.contains(".frame(width: metadataIconFrameWidth, alignment: .center)"))
    #expect(!source.contains(".onHover"))
  }

  @Test("reviewer summary source uses compact inline chrome instead of a pill")
  func reviewerSummarySourceUsesCompactInlineChrome() throws {
    let source = try rowSource(named: "DashboardReviewListRow+ReviewerSummary.swift")
    #expect(source.contains("Label(summary.compactLabel, systemImage: \"person.2\")"))
    #expect(!source.contains("DashboardReviewerSummaryPill("))
  }

  @Test("reviewer pills share the avatar cache path")
  func reviewerPillsShareTheAvatarCachePath() throws {
    let source = try rowSource(named: "DashboardReviewsReviewLabelLists.swift")
    #expect(source.contains("AvatarImageView("))
    #expect(!source.contains("AsyncImage("))
    #expect(source.contains("store.reviewAvatarImage("))
  }

  @Test("preview fixtures exercise author roles and requested-review state")
  func previewFixturesExerciseAuthorRolesAndRequestedReviewState() throws {
    let source = try appSource(
      "Sources/HarnessMonitorKit/Support/PreviewHarnessClientFixtures+Defaults.swift"
    )
    #expect(source.contains("authorAssociation: .member"))
    #expect(source.contains("authorAssociation: .contributor"))
    #expect(source.contains("authorAssociation: .firstTimeContributor"))
    #expect(source.contains("viewerIsRequestedReviewer: true"))
  }

  @Test("row source renders pinned emphasis through row chrome instead of a title icon")
  func rowSourceRendersPinnedEmphasisThroughRowChrome() throws {
    let source =
      try rowSource(named: "DashboardReviewRow.swift")
      + "\n"
      + rowSource(named: "DashboardReviewListRow.swift")
    #expect(source.contains("let base = isPinned ? HarnessMonitorTheme.accent"))
    #expect(source.contains("return base.opacity(0.05)"))
    #expect(!source.contains("dashboardReviewPinnedIndicator("))
  }

  @Test("selected rows use route selection state for high-contrast styling")
  func selectedRowsUseRouteSelectionStateForHighContrastStyling() throws {
    let contentRows = try rowSource(named: "DashboardReviewsRouteView+ContentRows.swift")
    // The selection-contrast chrome (derived flag + selected text color) moved
    // into the +Chrome companion, and the pill contrast flag into the
    // VisualComponents +Pills companion. Union-read each base with its
    // companion so every pinned literal resolves.
    let listRow =
      try rowSource(named: "DashboardReviewListRow.swift")
      + "\n"
      + rowSource(named: "DashboardReviewListRow+Chrome.swift")
    let labels = try rowSource(named: "DashboardReviewListRow+Labels.swift")
    let reviewer = try rowSource(named: "DashboardReviewListRow+ReviewerSummary.swift")
    let pills =
      try rowSource(named: "DashboardReviewsVisualComponents.swift")
      + "\n"
      + rowSource(named: "DashboardReviewsVisualComponents+Pills.swift")
    let chips = try rowSource(named: "DashboardReviewsReviewLabelLists.swift")
    let attentionIcons = try rowSource(named: "DashboardReviewListRow+AttentionIcons.swift")
    let markdown = try appSource(
      "Sources/HarnessMonitorUIPreviewable/Support/Markdown/HarnessMarkdownColorSettings.swift"
    )

    #expect(contentRows.contains("isSelected: routeSelectedIDs.contains(item.pullRequestID)"))
    #expect(listRow.contains("var usesSelectedBackgroundContrast: Bool"))
    #expect(listRow.contains("isSelected"))
    #expect(!listRow.contains("@State private var appKitSelectionIsActive"))
    #expect(!listRow.contains("DashboardReviewRowSelectionProbe"))
    #expect(!listRow.contains("observe(\\.isSelected"))
    #expect(listRow.contains("Color(nsColor: .alternateSelectedControlTextColor)"))
    #expect(
      listRow.contains(
        "colors: usesSelectedBackgroundContrast ? .selectedRow : .default"
      )
    )
    #expect(listRow.contains("usesSelectedBackgroundContrast: usesSelectedBackgroundContrast"))
    #expect(labels.contains("usesSelectedBackgroundContrast: usesSelectedBackgroundContrast"))
    #expect(reviewer.contains("usesSelectedBackgroundContrast: usesSelectedBackgroundContrast"))
    #expect(pills.contains("var usesSelectedBackgroundContrast = false"))
    #expect(pills.contains("Color(nsColor: .alternateSelectedControlTextColor)"))
    #expect(chips.contains("if usesSelectedBackgroundContrast"))
    #expect(
      attentionIcons.contains(
        "usesSelectedBackgroundContrast: usesSelectedBackgroundContrast"
      )
    )
    #expect(markdown.contains("static let selectedRow = Self("))
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

  func rowSource(named fileName: String) throws -> String {
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

  fileprivate func appSource(_ appLocalPath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = appRoot.appendingPathComponent(appLocalPath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
