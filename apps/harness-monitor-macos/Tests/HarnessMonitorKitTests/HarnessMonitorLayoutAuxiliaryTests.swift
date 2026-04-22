import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Content inspector visibility policy")
struct ContentInspectorVisibilityPolicyTests {
  @Test("Initial presentation keeps the inspector hidden when no preference exists")
  func initialPresentationKeepsInspectorHiddenWithoutPreference() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)

    #expect(ContentInspectorInitialPresentation.resolve(defaults: defaults) == false)
  }

  @Test("Initial presentation uses the persisted preference without a hydration pass")
  func initialPresentationUsesPersistedPreferenceImmediately() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defaults.set(false, forKey: "showInspector")

    #expect(ContentInspectorInitialPresentation.resolve(defaults: defaults) == false)
  }

  @Test("Explicit user toggles persist the preference")
  func explicitUserTogglesPersistPreference() {
    let change = ContentInspectorVisibilityPolicy.resolve(
      currentPresentation: true,
      currentPersistedPreference: true,
      nextPresentation: false,
      source: .explicitUserPreference
    )

    #expect(change?.nextPresentation == false)
    #expect(change?.persistedPreference == false)
  }

  @Test("Framework-driven presentation changes do not persist preference")
  func frameworkDrivenChangesRemainEphemeral() {
    let change = ContentInspectorVisibilityPolicy.resolve(
      currentPresentation: true,
      currentPersistedPreference: true,
      nextPresentation: false,
      source: .framework
    )

    #expect(change?.nextPresentation == false)
    #expect(change?.persistedPreference == nil)
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
  @Test("Inspector label follows presentation state")
  func inspectorLabelFollowsPresentationState() {
    let shown = ContentWindowToolbarModel(
      canNavigateBack: false,
      canNavigateForward: false,
      canStartNewSession: false,
      isRefreshing: false,
      sleepPreventionEnabled: false,
      showInspector: true
    )
    let hidden = ContentWindowToolbarModel(
      canNavigateBack: false,
      canNavigateForward: false,
      canStartNewSession: false,
      isRefreshing: false,
      sleepPreventionEnabled: false,
      showInspector: false
    )

    #expect(shown.inspectorToggleTitle == "Hide Inspector")
    #expect(hidden.inspectorToggleTitle == "Show Inspector")
  }

  @Test("Sleep prevention presentation follows enabled state")
  func sleepPreventionPresentationFollowsEnabledState() {
    let enabled = ContentWindowToolbarModel(
      canNavigateBack: false,
      canNavigateForward: false,
      canStartNewSession: false,
      isRefreshing: false,
      sleepPreventionEnabled: true,
      showInspector: false
    )
    let disabled = ContentWindowToolbarModel(
      canNavigateBack: false,
      canNavigateForward: false,
      canStartNewSession: false,
      isRefreshing: false,
      sleepPreventionEnabled: false,
      showInspector: false
    )

    #expect(enabled.sleepPreventionTitle == "Sleep Prevention On")
    #expect(enabled.sleepPreventionSystemImage == "moon.zzz.fill")
    #expect(disabled.sleepPreventionTitle == "Prevent Sleep")
    #expect(disabled.sleepPreventionSystemImage == "moon.zzz")
  }
}

@Suite("Agents viewport auto-resize stabilization")
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

  @MainActor
  @Test("Zero-size viewports do not auto-resize to the row/col minimum")
  func zeroSizeViewportsDoNotAutoResizeToMinimum() {
    let collapsed = AgentTuiWindowView.TerminalViewportSizing.terminalSize(
      for: CGSize(width: 0, height: 0),
      fontScale: 1
    )

    #expect(collapsed == nil)
  }

  @MainActor
  @Test("Tiny transient viewports bail out instead of snapping to 9x20")
  func tinyTransientViewportsBailOut() {
    let tiny = AgentTuiWindowView.TerminalViewportSizing.terminalSize(
      for: CGSize(width: 40, height: 30),
      fontScale: 1
    )

    #expect(tiny == nil)
  }

  @MainActor
  @Test("A usable viewport still produces a measured terminal size")
  func usableViewportProducesMeasuredSize() {
    let measured = AgentTuiWindowView.TerminalViewportSizing.terminalSize(
      for: CGSize(width: 900, height: 600),
      fontScale: 1
    )

    #expect(measured != nil)
    if let measured {
      #expect(measured.rows >= 20)
      #expect(measured.cols >= 60)
    }
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
