import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Signal filter preset")
struct SessionTimelineSignalFilterPresetTests {
  @Test("All three signal kinds in eventTypes activates preset")
  func allThreeKindsActivatesPreset() {
    var filters = SessionTimelineFilterState()
    filters.eventTypes = ["signal_sent", "signal_received", "signal_acknowledged"]
    #expect(filters.signalPresetActive)
  }

  @Test("Only two signal kinds does not activate preset")
  func twoKindsDoesNotActivatePreset() {
    var filters = SessionTimelineFilterState()
    filters.eventTypes = ["signal_sent", "signal_received"]
    #expect(!filters.signalPresetActive)
  }

  @Test("Toggle preset on adds all three signal kinds")
  func togglePresetOnAddsThreeKinds() {
    var filters = SessionTimelineFilterState()
    filters.toggleSignalPreset()
    #expect(filters.eventTypes.contains("signal_sent"))
    #expect(filters.eventTypes.contains("signal_received"))
    #expect(filters.eventTypes.contains("signal_acknowledged"))
    #expect(filters.signalPresetActive)
  }

  @Test("Toggle preset off removes signal kinds but preserves others")
  func togglePresetOffRemovesSignalKinds() {
    var filters = SessionTimelineFilterState()
    filters.eventTypes = [
      "signal_sent", "signal_received", "signal_acknowledged", "tool_result",
    ]
    filters.toggleSignalPreset()
    #expect(!filters.signalPresetActive)
    #expect(!filters.eventTypes.contains("signal_sent"))
    #expect(!filters.eventTypes.contains("signal_received"))
    #expect(!filters.eventTypes.contains("signal_acknowledged"))
    #expect(filters.eventTypes.contains("tool_result"))
  }

  @Test("Signal count sums all three signal kind counts from inventory")
  func signalCountSumsAllThreeKinds() {
    let nodes: [SessionTimelineNode] = [
      makeNode(id: "n1", kind: "signal_sent"),
      makeNode(id: "n2", kind: "signal_received"),
      makeNode(id: "n3", kind: "signal_acknowledged"),
      makeNode(id: "n4", kind: "signal_sent"),
      makeNode(id: "n5", kind: "tool_result"),
    ]
    let inventory = SessionTimelineFilterInventory(nodes: nodes, filters: .init())
    #expect(inventory.signalCount == 4)
  }

  @Test("Signal filter preset matches only signal_ rows and excludes others")
  func signalPresetFiltersMatchSignalRows() {
    let nodes: [SessionTimelineNode] = [
      makeNode(id: "n1", kind: "signal_sent"),
      makeNode(id: "n2", kind: "tool_result"),
      makeNode(id: "n3", kind: "signal_acknowledged"),
    ]
    var filters = SessionTimelineFilterState()
    filters.toggleSignalPreset()
    let matched = nodes.filter { SessionTimelineFilterSnapshot.matches(node: $0, filters: filters) }
    #expect(matched.map(\.id).sorted() == ["entry:n1", "entry:n3"])
  }
}

private func makeNode(id: String, kind: String) -> SessionTimelineNode {
  SessionTimelineNode(
    identity: .entry(id),
    kind: .event,
    timestamp: .distantPast,
    rawTimestamp: nil,
    sourceLabel: kind,
    entryKind: kind,
    title: "test",
    detail: nil,
    eventTone: nil,
    decision: nil
  )
}
