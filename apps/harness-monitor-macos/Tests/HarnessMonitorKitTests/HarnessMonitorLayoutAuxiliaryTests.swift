import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Content inspector visibility policy")
struct ContentInspectorVisibilityPolicyTests {
  @Test("Explicit user toggles persist the preference and suppress layout geometry")
  func explicitUserTogglesPersistPreference() {
    let change = ContentInspectorVisibilityPolicy.resolve(
      currentPresentation: true,
      currentPersistedPreference: true,
      nextPresentation: false,
      source: .explicitUserPreference
    )

    #expect(change?.nextPresentation == false)
    #expect(change?.persistedPreference == false)
    #expect(change?.shouldSuppressLayoutGeometry == true)
  }

  @Test("Framework-driven presentation changes do not persist or suppress layout geometry")
  func frameworkDrivenChangesRemainEphemeral() {
    let change = ContentInspectorVisibilityPolicy.resolve(
      currentPresentation: true,
      currentPersistedPreference: true,
      nextPresentation: false,
      source: .framework
    )

    #expect(change?.nextPresentation == false)
    #expect(change?.persistedPreference == nil)
    #expect(change?.shouldSuppressLayoutGeometry == false)
  }

  @Test("Contextual auto-open keeps the persisted preference unchanged")
  func contextualAutoOpenDoesNotRewritePreference() {
    let change = ContentInspectorVisibilityPolicy.resolve(
      currentPresentation: false,
      currentPersistedPreference: false,
      nextPresentation: true,
      source: .contextualAutoOpen
    )

    #expect(change?.nextPresentation == true)
    #expect(change?.persistedPreference == nil)
    #expect(change?.shouldSuppressLayoutGeometry == true)
  }

  @Test("Persisted preference sync updates presentation without writing back to storage")
  func persistedPreferenceSyncDoesNotRepersist() {
    let change = ContentInspectorVisibilityPolicy.resolve(
      currentPresentation: false,
      currentPersistedPreference: true,
      nextPresentation: true,
      source: .persistedPreference
    )

    #expect(change?.nextPresentation == true)
    #expect(change?.persistedPreference == nil)
    #expect(change?.shouldSuppressLayoutGeometry == true)
  }
}

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

@Suite("Toolbar centerpiece display mode stabilization")
struct ToolbarCenterpieceDisplayModeStabilizationTests {
  @Test("Standard mode ignores single-bucket activation jitter near the compact threshold")
  func standardModeIgnoresSingleBucketActivationJitter() {
    let stabilized = ToolbarCenterpieceDisplayMode.resolve(
      current: .standard,
      detailWidth: 1_024
    )

    #expect(stabilized == .standard)
  }

  @Test("Compact mode ignores single-bucket activation jitter near the standard threshold")
  func compactModeIgnoresSingleBucketStandardThresholdJitter() {
    let stabilized = ToolbarCenterpieceDisplayMode.resolve(
      current: .compact,
      detailWidth: 1_056
    )

    #expect(stabilized == .compact)
  }

  @Test("Compact mode ignores single-bucket activation jitter near the compressed threshold")
  func compactModeIgnoresSingleBucketCompressedThresholdJitter() {
    let stabilized = ToolbarCenterpieceDisplayMode.resolve(
      current: .compact,
      detailWidth: 928
    )

    #expect(stabilized == .compact)
  }

  @Test("Compressed mode only promotes after width moves beyond the compact entry band")
  func compressedModePromotesOnlyAfterMeaningfulGrowth() {
    let stabilized = ToolbarCenterpieceDisplayMode.resolve(
      current: .compressed,
      detailWidth: 992
    )

    #expect(stabilized == .compact)
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

@Suite("Agent TUI viewport auto-resize stabilization")
struct AgentTuiViewportAutoResizeStabilizationTests {
  @Test("Minor viewport jitter preserves the current terminal size")
  func minorViewportJitterPreservesCurrentTerminalSize() {
    let stabilized = AgentTuiWindowView.TerminalViewportSizing.stabilizedAutomaticSize(
      measured: AgentTuiSize(rows: 49, cols: 122),
      baseline: AgentTuiSize(rows: 48, cols: 120)
    )

    #expect(stabilized == AgentTuiSize(rows: 48, cols: 120))
  }

  @Test("Meaningful viewport changes still auto-resize the terminal")
  func meaningfulViewportChangesStillAutoResizeTheTerminal() {
    let stabilized = AgentTuiWindowView.TerminalViewportSizing.stabilizedAutomaticSize(
      measured: AgentTuiSize(rows: 52, cols: 126),
      baseline: AgentTuiSize(rows: 48, cols: 120)
    )

    #expect(stabilized == AgentTuiSize(rows: 52, cols: 126))
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
