import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas accessibility")
@MainActor
struct PolicyCanvasAccessibilityTests {
  @Test("node accessibility label is composed from kind and title")
  func nodeAccessibilityLabelIsComposedFromTitle() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let node = viewModel.node("policy-source") else {
      Issue.record("expected policy-source sample node")
      return
    }

    let label = viewModel.accessibilityLabel(for: node)

    #expect(label == "Source Policy intake")
  }

  @Test("node accessibility value lists outgoing connections")
  func nodeAccessibilityValueListsConnectedNodes() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let node = viewModel.node("risk-score") else {
      Issue.record("expected risk-score sample node")
      return
    }

    let value = viewModel.accessibilityValue(for: node)

    #expect(value.contains("Context map"))
    #expect(value.contains("Review gate"))
    #expect(value.contains("group Evaluation"))
  }

  @Test("edge accessibility label includes source and target context")
  func edgeAccessibilityLabelIncludesSourceAndTargetContext() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let edge = viewModel.edges.first(where: { $0.id == "edge-intake-risk" }) else {
      Issue.record("expected edge-intake-risk sample edge")
      return
    }

    let label = viewModel.accessibilityLabel(for: edge)

    #expect(label == "Edge normalize, from Policy intake event to Risk score event")
  }

  @Test("port diameter meets the accessibility hit-test floor")
  func portDiameterMeetsAccessibilityFloor() {
    #expect(PolicyCanvasLayout.portDiameter >= 18)
    #expect(PolicyCanvasLayout.portHitTestExtension >= 8)
  }
}
