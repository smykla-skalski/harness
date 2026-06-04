import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension DashboardReviewListRowAccessibilityTests {
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

  @Test("row source aligns leading chrome to the first title line")
  func rowSourceAlignsLeadingChromeToTheFirstTitleLine() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    #expect(source.contains("HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM)"))
    #expect(source.contains(".frame(height: titleLineHeight, alignment: .center)"))
  }

  @Test("row source caches inline-code title fragments off the body path")
  func rowSourceCachesInlineCodeTitleFragmentsOffTheBodyPath() throws {
    let source = try rowSource(named: "DashboardReviewListRow.swift")
    #expect(source.contains("private let displayTitleInlines: [HarnessMarkdownInline]?"))
    #expect(source.contains("let titleAccessibilityText: String"))
    #expect(source.contains("HarnessMarkdownInlineRenderer.attributedString("))
  }

  @Test("labels strip caps visible chips at six and surfaces overflow")
  func labelsStripCapsVisibleChipsAtSixAndSurfacesOverflow() {
    let manyLabels = (1...10).map { "label-\($0)" }
    let strip = DashboardReviewListRowLabelsStrip(labels: manyLabels)
    let source = try? rowSource(named: "DashboardReviewListRow+Labels.swift")
    #expect(source?.contains("visibleCap = 6") == true)
    #expect(strip.labels == manyLabels)
  }

  @Test("labels strip stores a precomputed per-name colour lookup")
  func labelsStripStoresPrecomputedColourLookup() {
    let descriptors = [
      ReviewRepositoryLabel(name: "bug", color: "d73a4a", description: "Something is broken"),
      ReviewRepositoryLabel(name: "enhancement", color: "a2eeef", description: nil),
    ]
    let labelByName = Dictionary(
      descriptors.map { ($0.name, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let strip = DashboardReviewListRowLabelsStrip(
      labels: ["bug", "enhancement", "missing-descriptor"],
      labelByName: labelByName
    )
    #expect(strip.labelByName.count == 2)
    #expect(strip.labelByName["bug"]?.color == "d73a4a")
    let bare = DashboardReviewListRowLabelsStrip(labels: ["wip"])
    #expect(bare.labelByName.isEmpty)
  }

  @Test("route view passes per-repository label lookup into each row")
  func routeViewPassesPerRepositoryLabelLookupIntoEachRow() throws {
    let source = try rowSource(named: "DashboardReviewsRouteView+ContentRows.swift")
    #expect(
      source.contains(
        "repositoryLabelByName: routeLabelMenuDataByRepository[item.repository]?.labelByName ?? [:]"
      )
    )
  }
}
