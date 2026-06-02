import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas scene storage")
@MainActor
struct PolicyCanvasSceneStorageTests {
  @Test("encode selection round-trips node, edge, and group cases")
  func encodeSelectionRoundTripsAllCases() {
    let cases: [PolicyCanvasSelection] = [
      .node("node-abc123"),
      .edge("edge-def456"),
      .group("group-ghi789"),
    ]

    for selection in cases {
      let raw = PolicyCanvasView.encodeSelection(selection)
      let decoded = PolicyCanvasView.decodeSelection(raw)
      #expect(decoded == selection)
    }
  }

  @Test("nil selection encodes to empty string and decodes back to nil")
  func nilSelectionEncodesEmptyDecodesNil() {
    let raw = PolicyCanvasView.encodeSelection(nil)
    let decoded = PolicyCanvasView.decodeSelection(raw)

    #expect(raw.isEmpty)
    #expect(decoded == nil)
  }

  @Test("decoding an unknown prefix returns nil rather than crashing")
  func decodeUnknownPrefixReturnsNil() {
    let result = PolicyCanvasView.decodeSelection("widget:something")
    #expect(result == nil)
  }

  @Test("decoding a malformed string without separator returns nil")
  func decodeMalformedReturnsNil() {
    let result = PolicyCanvasView.decodeSelection("not-a-real-selection")
    #expect(result == nil)
  }

  @Test("decoding a prefix-only string returns nil")
  func decodePrefixOnlyReturnsNil() {
    let result = PolicyCanvasView.decodeSelection("node:")
    #expect(result == nil)
  }

  @Test("encoded form uses kind colon id contract")
  func encodedFormUsesContract() {
    #expect(PolicyCanvasView.encodeSelection(.node("a")) == "node:a")
    #expect(PolicyCanvasView.encodeSelection(.edge("b")) == "edge:b")
    #expect(PolicyCanvasView.encodeSelection(.group("c")) == "group:c")
  }

  @Test("scene state lookup returns the current pipeline slot")
  func sceneStateLookupReturnsStoredPipelineSlot() {
    let raw = PolicyCanvasView.encodePipelineStateMap([
      "trace-policy": PolicyCanvasPipelineSceneState(
        zoom: 1.2,
        selectionRaw: PolicyCanvasView.encodeSelection(.edge("edge-1")),
        viewportOriginX: 240,
        viewportOriginY: 360,
        viewportWidth: 900,
        viewportHeight: 640
      )
    ])

    let state = PolicyCanvasView.sceneState(
      for: "trace-policy",
      raw: raw
    )

    #expect(state?.zoom == 1.2)
    #expect(state?.selectionRaw == "edge:edge-1")
    #expect(state?.viewportOrigin == CGPoint(x: 240, y: 360))
    #expect(state?.viewportRect == CGRect(x: 240, y: 360, width: 900, height: 640))
  }

  @Test("scene state lookup respects suppression")
  func sceneStateLookupRespectsSuppression() {
    let raw = PolicyCanvasView.encodePipelineStateMap([
      "trace-policy": PolicyCanvasPipelineSceneState(zoom: 0.9, selectionRaw: "")
    ])

    let state = PolicyCanvasView.sceneState(
      for: "trace-policy",
      raw: raw,
      suppressesSceneStorage: true
    )

    #expect(state == nil)
  }
}
