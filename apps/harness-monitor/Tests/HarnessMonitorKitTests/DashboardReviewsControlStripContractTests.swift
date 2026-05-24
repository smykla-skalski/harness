import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Source-grep contract test for `DashboardReviewsControlStrip`.
///
/// The control strip is pure SwiftUI view code with no testable business
/// logic of its own — selection plumbing is the binding's caller's
/// responsibility. The only contract worth pinning at the unit level is
/// that the control strip's documented accessibility handles survive future
/// SwiftUI restructures. An XCUI test could verify the handles
/// end-to-end but pays a multi-minute launch cost; this source check is
/// instant and catches the same regression class (someone renamed a
/// binding and forgot to update the `.accessibilityIdentifier(...)`).
@Suite("Dashboard reviews control strip accessibility handles")
@MainActor
struct DashboardReviewsControlStripContractTests {
  @Test("control strip source attaches every documented accessibility identifier")
  func controlStripSourceAttachesEveryDocumentedAccessibilityIdentifier() throws {
    let source = try controlStripSource()
    let expected = [
      "HarnessMonitorAccessibility.dashboardReviewsNeedsMeToggle",
      "HarnessMonitorAccessibility.dashboardReviewsFilterPicker",
      "HarnessMonitorAccessibility.dashboardReviewsSortPicker",
      "HarnessMonitorAccessibility.dashboardReviewsGroupPicker",
      "HarnessMonitorAccessibility.dashboardReviewsCategoryToggle",
      "HarnessMonitorAccessibility.dashboardReviewsShowRowAvatarsToggle",
      "HarnessMonitorAccessibility.dashboardReviewsShowRowLabelsToggle",
      "HarnessMonitorAccessibility.dashboardReviewsShowRowLineCountersToggle",
      "HarnessMonitorAccessibility.dashboardReviewsShowRowPullRequestNumberToggle",
      "HarnessMonitorAccessibility.dashboardReviewsShowRowPullRequestAgeToggle",
      "HarnessMonitorAccessibility.dashboardReviewsWrapRowTitlesToggle",
      "HarnessMonitorAccessibility.dashboardReviewsHideSemanticPrefixesInRowTitlesToggle",
    ]
    for identifier in expected {
      #expect(
        source.contains(".accessibilityIdentifier(\(identifier))")
          || source.contains("accessibilityIdentifier: \(identifier)"),
        "Control strip must keep \(identifier) wired"
      )
    }
  }

  @Test("control strip renders the needs-me count as a circular notification badge")
  func controlStripRendersNeedsMeCountAsCircularBadge() throws {
    let source = try controlStripSource()
    // The visual contract distinguishes the needs-me notification badge
    // (Capsule-backed, see AGENTS.md) from the per-repo count pill
    // (RoundedRectangle via `harnessControlPillGlass`). If a refactor
    // collapses both into the same shape the at-a-glance distinction
    // documented in AGENTS.md is lost.
    #expect(source.contains("private var needsMeCountBadge"))
    #expect(source.contains("Capsule(style: .continuous)"))
  }

  @Test("control strip uses icon-led menu labels, not legacy `Sort:`/`Filter:` prefixes")
  func controlStripUsesIconLedMenuLabels() throws {
    let source = try controlStripSource()
    // The icon-led restyle moved Filter / Sort / Group into a shared
    // `refineMenu(systemImage:...)` helper so each menu label shows an
    // SF Symbol + current value + chevron instead of the redundant
    // "Filter: All open" prefix the legacy pickers rendered.
    #expect(source.contains("private func refineMenu("))
    #expect(source.contains("systemImage: \"line.3.horizontal.decrease.circle\""))
    #expect(source.contains("systemImage: \"arrow.up.arrow.down.circle\""))
    #expect(source.contains("systemImage: \"square.stack.3d.up\""))
  }

  private func controlStripSource() throws -> String {
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
      .appendingPathComponent("DashboardReviewsControlStrip.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
