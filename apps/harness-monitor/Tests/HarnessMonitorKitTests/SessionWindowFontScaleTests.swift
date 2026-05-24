import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session window font scale")
struct SessionWindowFontScaleTests {
  @Test("Session font scale uses the app text-size storage key")
  func sessionFontScaleUsesAppTextSizeStorageKey() {
    #expect(SessionWindowFontScale.storageKey == HarnessMonitorTextSize.storageKey)
  }

  @Test("Session metrics clamp extreme font scales centrally")
  func sessionMetricsClampExtremeFontScalesCentrally() {
    #expect(SessionWindowFontScale.metricsScale(for: 0.1) == 0.85)
    #expect(SessionWindowFontScale.metricsScale(for: 1.0) == 1.0)
    #expect(SessionWindowFontScale.metricsScale(for: 9.0) == 1.8)
  }

  @Test("Session font scale resolves through normalized text-size indices")
  func sessionFontScaleResolvesThroughNormalizedTextSizeIndices() {
    #expect(SessionWindowFontScale.scale(at: -10) == HarnessMonitorTextSize.scale(at: 0))
    #expect(
      SessionWindowFontScale.scale(at: 10)
        == HarnessMonitorTextSize.scale(at: HarnessMonitorTextSize.scales.count - 1)
    )
  }

  @Test("Native input sizing follows the app text size")
  func nativeInputSizingFollowsAppTextSize() {
    let largestIndex = HarnessMonitorTextSize.scales.count - 1

    #expect(HarnessMonitorTextSize.nativeInputIndex(0) == 0)
    #expect(HarnessMonitorTextSize.nativeInputIndex(largestIndex) == largestIndex)
    #expect(
      HarnessMonitorTextSize.nativeInputFont(at: largestIndex)
        == HarnessMonitorTextSize.nativeFormControlFont(at: largestIndex)
    )
    #expect(
      HarnessMonitorTextSize.nativeInputControlSize(at: largestIndex)
        == HarnessMonitorTextSize.controlSize(at: largestIndex)
    )
  }

  @MainActor
  @Test("Session font scale view modifier remains available to SwiftUI surfaces")
  func sessionFontScaleViewModifierCompilesForSwiftUISurfaces() {
    _ = Text("Session").sessionFontScale(1.2)
    _ = Text("Session").sessionFontScale(textSizeIndex: HarnessMonitorTextSize.defaultIndex)
  }
}
