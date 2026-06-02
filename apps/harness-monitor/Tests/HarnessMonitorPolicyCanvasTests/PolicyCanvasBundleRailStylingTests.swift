import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas

@Suite("Policy canvas bundle rail styling")
struct PolicyCanvasBundleRailStylingTests {
  @Test("hue offset is zero for a single-rail bundle")
  func hueOffsetZeroForSingleton() {
    let offset = policyCanvasBundleHueOffsetDegrees(bundleOrdinal: 0, bundleSize: 1)
    #expect(offset == 0)
  }

  @Test("hue offset spreads symmetric ordinals around zero for an even bundle")
  func hueOffsetSymmetricForEvenBundle() {
    let bundleSize = 4
    var observed: [Double] = []
    for ordinal in 0..<bundleSize {
      observed.append(
        policyCanvasBundleHueOffsetDegrees(bundleOrdinal: ordinal, bundleSize: bundleSize)
      )
    }
    let sum = observed.reduce(0, +)
    #expect(abs(sum) < 0.001, "Even-bundle offsets should sum to zero; got \(observed)")
  }

  @Test("hue offset stays inside the configured span")
  func hueOffsetStaysInsideSpan() {
    let bundleSize = 5
    for ordinal in 0..<bundleSize {
      let offset = policyCanvasBundleHueOffsetDegrees(
        bundleOrdinal: ordinal,
        bundleSize: bundleSize
      )
      #expect(
        abs(offset) <= policyCanvasBundleHueSpanDegrees / 2 + 0.001,
        "Offset for ordinal \(ordinal) of \(bundleSize) was \(offset) - outside half-span"
      )
    }
  }

  @Test("dash pattern returns the kind pattern verbatim for a single rail")
  func dashPatternKeepsKindForSingleton() {
    let kindDash: [CGFloat] = [8, 4]
    let pattern = policyCanvasBundleRailDashPattern(
      kindDashPattern: kindDash,
      bundleOrdinal: 0,
      bundleSize: 1
    )
    #expect(pattern == kindDash)
  }

  @Test("dash pattern produces distinct entries across a multi-rail bundle")
  func dashPatternDistinctForBundle() {
    let kindDash: [CGFloat] = []
    let patterns = (0..<4).map { ordinal in
      policyCanvasBundleRailDashPattern(
        kindDashPattern: kindDash,
        bundleOrdinal: ordinal,
        bundleSize: 4
      )
    }
    let unique = Set(
      patterns.map { pattern in
        pattern.map { String(Double($0)) }.joined(separator: ",")
      })
    #expect(unique.count == 4)
  }
}
