import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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

    #expect(raw == "")
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
}
