import AppKit
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Behavioral coverage for the Open Anything palette appearance wiring.
///
/// The source-contract tests only prove the modifiers are *present*; these
/// render the real palette views and measure the effect, so an inert wiring
/// (reading the wrong environment key, or a toggle that never reaches the glass
/// surface) fails here rather than passing a string match.
@MainActor
@Suite("Open Anything palette appearance")
struct OpenAnythingPaletteAppearanceTests {
  /// The result row is the per-result LazyVStack element whose `.scaledFont`
  /// text was the original font-scaling perf concern. Rendering it at the
  /// smallest vs largest app text size must change its laid-out height, proving
  /// the row honors `\.fontScale` rather than rendering a fixed size.
  @Test("Result row text grows with the app font scale")
  func resultRowGrowsWithFontScale() {
    let smallest = rowFittingSize(scale: HarnessMonitorTextSize.scale(at: 0))
    let largest = rowFittingSize(
      scale: HarnessMonitorTextSize.scale(at: HarnessMonitorTextSize.scales.count - 1)
    )
    #expect(largest.height > smallest.height)
  }

  /// The footer exercises the same `.scaledFont` path with pure text (no icon
  /// column), so its height tracks the scale directly.
  @Test("Footer text grows with the app font scale")
  func footerGrowsWithFontScale() {
    let smallest = footerFittingSize(scale: HarnessMonitorTextSize.scale(at: 0))
    let largest = footerFittingSize(
      scale: HarnessMonitorTextSize.scale(at: HarnessMonitorTextSize.scales.count - 1)
    )
    #expect(largest.height > smallest.height)
  }

  /// Default-on contract: the transparency gate defaults to `true`, so every
  /// glass surface other than the palette keeps its translucency untouched. The
  /// Settings toggle only flips this value for the Open Anything window.
  @Test("Floating glass transparency defaults to enabled")
  func floatingGlassTransparencyDefaultsEnabled() {
    #expect(EnvironmentValues().harnessFloatingGlassTransparencyEnabled)
  }

  private func rowFittingSize(scale: CGFloat) -> CGSize {
    let host = NSHostingView(
      rootView: OpenAnythingPaletteRow(
        hit: Self.sampleHit,
        isSelected: false,
        isPinned: false,
        chordHint: "⌘1",
        onActivate: { _ in },
        onHover: {},
        onTogglePin: {},
        onCopyID: {}
      )
      .environment(\.fontScale, scale)
    )
    host.frame = CGRect(x: 0, y: 0, width: 520, height: 200)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  private func footerFittingSize(scale: CGFloat) -> CGSize {
    let host = NSHostingView(
      rootView: OpenAnythingPaletteFooter(recordCount: 128)
        .environment(\.fontScale, scale)
    )
    host.frame = CGRect(x: 0, y: 0, width: 520, height: 120)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  private static let sampleHit = OpenAnythingHit(
    record: OpenAnythingRecord(
      id: "sample.row",
      domain: .reviews,
      target: .review(pullRequestID: "1"),
      title: "Sample pull request title that fills the result row",
      subtitle: "owner/repo #1",
      trailing: "open"
    ),
    highlights: .empty,
    score: 0
  )
}
