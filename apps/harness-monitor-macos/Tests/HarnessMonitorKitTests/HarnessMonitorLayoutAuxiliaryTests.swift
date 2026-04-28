import AppKit
import CoreText
import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Adaptive grid layout cache normalization")
struct HarnessMonitorAdaptiveGridLayoutCacheTests {
  @Test("Sub-point width jitter collapses to one cache width")
  func subPointWidthJitterCollapsesToOneCacheWidth() {
    #expect(HarnessMonitorAdaptiveGridLayout.normalizedCacheWidth(720.1) == 720)
    #expect(HarnessMonitorAdaptiveGridLayout.normalizedCacheWidth(720.9) == 720)
  }

  @Test("Whole-point width changes still invalidate the cache")
  func wholePointWidthChangesStillInvalidateTheCache() {
    #expect(HarnessMonitorAdaptiveGridLayout.normalizedCacheWidth(720.0) == 720)
    #expect(HarnessMonitorAdaptiveGridLayout.normalizedCacheWidth(723.0) == 720)
    #expect(HarnessMonitorAdaptiveGridLayout.normalizedCacheWidth(724.0) == 724)
  }

  @Test("Cache only invalidates when the subview count changes")
  func cacheOnlyInvalidatesWhenSubviewCountChanges() {
    #expect(
      HarnessMonitorAdaptiveGridLayout.shouldInvalidateCache(
        cachedSubviewCount: 4,
        newSubviewCount: 4
      ) == false
    )
    #expect(
      HarnessMonitorAdaptiveGridLayout.shouldInvalidateCache(
        cachedSubviewCount: 4,
        newSubviewCount: 5
      ) == true
    )
    #expect(
      HarnessMonitorAdaptiveGridLayout.shouldInvalidateCache(
        cachedSubviewCount: nil,
        newSubviewCount: 5
      ) == true
    )
  }
}

@Suite("Adaptive grid layout measurement key")
struct AdaptiveGridLayoutMeasurementKeyTests {
  @Test("Measurement key normalizes invalid widths to nil")
  func measurementKeyNormalizesInvalidWidths() {
    #expect(
      HarnessMonitorAdaptiveGridLayout.MeasurementKey.make(
        subviewCount: 2,
        width: nil
      ).width == nil
    )
    #expect(
      HarnessMonitorAdaptiveGridLayout.MeasurementKey.make(
        subviewCount: 2,
        width: 0
      ).width == nil
    )
    #expect(
      HarnessMonitorAdaptiveGridLayout.MeasurementKey.make(
        subviewCount: 2,
        width: -.infinity
      ).width == nil
    )
  }

  @Test("Measurement key tracks subview count")
  func measurementKeyTracksSubviewCount() {
    let left = HarnessMonitorAdaptiveGridLayout.MeasurementKey.make(
      subviewCount: 2,
      width: 640
    )
    let right = HarnessMonitorAdaptiveGridLayout.MeasurementKey.make(
      subviewCount: 3,
      width: 640
    )

    #expect(left != right)
  }

  @Test("Measurement key preserves a valid width")
  func measurementKeyPreservesValidWidth() {
    let key = HarnessMonitorAdaptiveGridLayout.MeasurementKey.make(
      subviewCount: 2,
      width: 640
    )

    #expect(key.subviewCount == 2)
    #expect(key.width == 640)
  }

  @Test("Measurement key buckets widths across minor jitter")
  func measurementKeyBucketsWidthsAcrossMinorJitter() {
    let left = HarnessMonitorAdaptiveGridLayout.MeasurementKey.make(
      subviewCount: 2,
      width: 640
    )
    let right = HarnessMonitorAdaptiveGridLayout.MeasurementKey.make(
      subviewCount: 2,
      width: 643
    )

    #expect(left == right)
    #expect(right.width == 640)
  }
}

@Suite("Content window toolbar model")
struct ContentWindowToolbarModelTests {
  @Test("Sleep prevention presentation follows enabled state")
  func sleepPreventionPresentationFollowsEnabledState() {
    let enabled = ContentWindowToolbarModel(
      canNavigateBack: false,
      canNavigateForward: false,
      canStartNewSession: false,
      isRefreshing: false,
      sleepPreventionEnabled: true
    )
    let disabled = ContentWindowToolbarModel(
      canNavigateBack: false,
      canNavigateForward: false,
      canStartNewSession: false,
      isRefreshing: false,
      sleepPreventionEnabled: false
    )

    #expect(enabled.sleepPreventionTitle == "Sleep Prevention On")
    #expect(enabled.sleepPreventionSystemImage == "moon.zzz.fill")
    #expect(disabled.sleepPreventionTitle == "Prevent Sleep")
    #expect(disabled.sleepPreventionSystemImage == "moon.zzz")
  }
}

@Suite("Agents viewport auto-resize stabilization")
struct AgentTuiViewportAutoResizeStabilizationTests {
  @Test("Pending viewport resize target remains the baseline while the server catches up")
  func pendingViewportResizeTargetRemainsBaselineWhileServerCatchesUp() {
    let baseline = AgentsWindowView.TerminalViewportSizing.automaticResizeBaseline(
      serverSize: AgentTuiSize(rows: 32, cols: 120),
      pendingTarget: AgentTuiSize(rows: 48, cols: 136),
      expectedSize: AgentTuiSize(rows: 48, cols: 136)
    )

    #expect(baseline == AgentTuiSize(rows: 48, cols: 136))
  }

  @Test("Expected viewport size stays authoritative across stale server snapshots")
  func expectedViewportSizeStaysAuthoritativeAcrossStaleServerSnapshots() {
    let baseline = AgentsWindowView.TerminalViewportSizing.automaticResizeBaseline(
      serverSize: AgentTuiSize(rows: 32, cols: 120),
      pendingTarget: nil,
      expectedSize: AgentTuiSize(rows: 48, cols: 136)
    )

    #expect(baseline == AgentTuiSize(rows: 48, cols: 136))
  }

  @MainActor
  @Test("Wide detail columns seed a container-derived terminal before the first live measurement")
  func wideDetailColumnsSeedContainerDerivedTerminalBeforeFirstLiveMeasurement() {
    let startSize = AgentsWindowView.TerminalViewportSizing.estimatedStartSize(
      detailColumnSize: CGSize(width: 1320, height: 860),
      fontScale: 1,
      fallbackRows: 32
    )

    #expect(startSize.rows < 32)
    #expect(startSize.rows >= 20)
    #expect(startSize.cols > 140)
  }

  @Test("Minor viewport jitter preserves the current terminal size")
  func minorViewportJitterPreservesCurrentTerminalSize() {
    let stabilized = AgentsWindowView.TerminalViewportSizing.stabilizedAutomaticSize(
      measured: AgentTuiSize(rows: 49, cols: 122),
      baseline: AgentTuiSize(rows: 48, cols: 120)
    )

    #expect(stabilized == AgentTuiSize(rows: 48, cols: 120))
  }

  @Test("Meaningful viewport changes still auto-resize the terminal")
  func meaningfulViewportChangesStillAutoResizeTheTerminal() {
    let stabilized = AgentsWindowView.TerminalViewportSizing.stabilizedAutomaticSize(
      measured: AgentTuiSize(rows: 52, cols: 126),
      baseline: AgentTuiSize(rows: 48, cols: 120)
    )

    #expect(stabilized == AgentTuiSize(rows: 52, cols: 126))
  }

  @MainActor
  @Test("Zero-size viewports do not auto-resize to the row/col minimum")
  func zeroSizeViewportsDoNotAutoResizeToMinimum() {
    let collapsed = AgentsWindowView.TerminalViewportSizing.terminalSize(
      for: CGSize(width: 0, height: 0),
      fontScale: 1
    )

    #expect(collapsed == nil)
  }

  @MainActor
  @Test("Tiny transient viewports bail out instead of snapping to 9x20")
  func tinyTransientViewportsBailOut() {
    let tiny = AgentsWindowView.TerminalViewportSizing.terminalSize(
      for: CGSize(width: 40, height: 30),
      fontScale: 1
    )

    #expect(tiny == nil)
  }

  @MainActor
  @Test("A usable viewport still produces a measured terminal size")
  func usableViewportProducesMeasuredSize() {
    let measured = AgentsWindowView.TerminalViewportSizing.terminalSize(
      for: CGSize(width: 900, height: 600),
      fontScale: 1
    )

    #expect(measured != nil)
    if let measured {
      #expect(measured.rows >= 20)
      #expect(measured.cols >= 60)
    }
  }

  @MainActor
  @Test("Terminal content width follows the negotiated column count")
  func terminalContentWidthFollowsNegotiatedColumnCount() {
    let narrow = AgentsWindowView.TerminalViewportSizing.contentWidth(
      for: AgentTuiSize(rows: 20, cols: 88),
      fontScale: 1
    )
    let wide = AgentsWindowView.TerminalViewportSizing.contentWidth(
      for: AgentTuiSize(rows: 20, cols: 119),
      fontScale: 1
    )

    #expect(wide > narrow)
  }

  @MainActor
  @Test("Terminal content width matches the rendered monospaced grid advance")
  func terminalContentWidthMatchesRenderedMonospacedGridAdvance() {
    let cols = 120
    let fontScale: CGFloat = 1
    let measured = AgentsWindowView.TerminalViewportSizing.contentWidth(
      for: AgentTuiSize(rows: 20, cols: cols),
      fontScale: fontScale
    )
    let font = NSFont.monospacedSystemFont(
      ofSize: 13 * max(fontScale, 0.78),
      weight: .regular
    )
    var character: UniChar = 87
    var glyph = CGGlyph()
    #expect(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    let expected = advance.width * CGFloat(cols)

    #expect(abs(measured - expected) < 1)
  }
}

@Suite("Interactive card hover state")
struct InteractiveCardHoverStateTests {
  @Test("Hover updates when the pointer enters or leaves")
  func hoverUpdatesWhenPointerStateChanges() {
    #expect(InteractiveCardHoverState.resolve(current: false, isHovering: true) == true)
    #expect(InteractiveCardHoverState.resolve(current: true, isHovering: false) == false)
  }

  @Test("Hover ignores redundant transitions")
  func hoverIgnoresRedundantTransitions() {
    #expect(InteractiveCardHoverState.resolve(current: false, isHovering: false) == nil)
    #expect(InteractiveCardHoverState.resolve(current: true, isHovering: true) == nil)
  }
}
