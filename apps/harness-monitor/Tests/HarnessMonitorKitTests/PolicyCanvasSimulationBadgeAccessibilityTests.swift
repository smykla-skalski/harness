import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

/// Covers the badge accessibility-label composition. The badge is a sibling
/// of the parent node card under `.contain` viewport accessibility, so its
/// label must not repeat the node title — the parent card already exposes
/// the title via its own `accessibilityValue`. Without this contract VO
/// reads the node identity twice (once on the card, once on this sibling).
@Suite("Policy canvas simulation badge a11y")
@MainActor
struct PolicyCanvasSimulationBadgeAccessibilityTests {
  @Test("allowed badge label is just the verdict word, no node title")
  func allowedLabelHasNoNodeTitle() {
    let label = PolicyCanvasSimulationBadgeKind.allowed.accessibilityLabel

    #expect(label == "allowed")
    #expect(!label.lowercased().contains("node"))
  }

  @Test("denied badge label is 'denied: <reason>', no node title")
  func deniedLabelComposesReasonWithoutNodeTitle() {
    let kind = PolicyCanvasSimulationBadgeKind.denied(reason: "merge_risk_high")
    let label = kind.accessibilityLabel

    #expect(label == "denied: merge_risk_high")
    #expect(!label.lowercased().contains("node"))
  }

  @Test("denied badge with empty reason falls back to bare verdict")
  func deniedLabelOmitsEmptyReason() {
    let kind = PolicyCanvasSimulationBadgeKind.denied(reason: "")
    let label = kind.accessibilityLabel

    #expect(label == "denied")
  }
}
