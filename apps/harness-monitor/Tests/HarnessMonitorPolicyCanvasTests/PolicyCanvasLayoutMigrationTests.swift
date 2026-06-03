import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas layout migration")
@MainActor
struct PolicyCanvasLayoutMigrationTests {
  @Test("mixed manual and automatic layout provenance round-trips through export")
  func mixedProvenanceRoundTripsThroughExport() {
    let initialViewModel = PolicyCanvasViewModel.sample()
    initialViewModel.load(
      document: overlappingDefaultPolicyDocument(revision: 910),
      simulation: nil,
      audit: nil
    )

    guard let manualIndex = initialViewModel.nodes.firstIndex(where: { $0.id == "action:router" })
    else {
      Issue.record("Expected action:router node in overlapping default policy fixture")
      return
    }
    let baselinePosition = initialViewModel.nodes[manualIndex].position
    let manualPosition = CGPoint(x: baselinePosition.x + 40, y: baselinePosition.y + 20)
    initialViewModel.nodes[manualIndex].position = manualPosition
    initialViewModel.nodes[manualIndex].layoutSource = .manual

    let exported = initialViewModel.exportDocument()
    let exportedSources = Dictionary(
      uniqueKeysWithValues: exported.layout.nodes.map { ($0.nodeId, $0.source) }
    )
    #expect(exportedSources["action:router"] == .manual)
    #expect(
      exported.layout.nodes.contains { layout in
        layout.nodeId != "action:router" && layout.source == .auto
      }
    )

    let reloadedViewModel = PolicyCanvasViewModel.sample()
    reloadedViewModel.load(document: exported, simulation: nil, audit: nil)

    #expect(reloadedViewModel.node("action:router")?.layoutSource == .manual)
    #expect(reloadedViewModel.node("action:router")?.position == manualPosition)
    #expect(
      reloadedViewModel.nodes.contains { node in
        node.id != "action:router" && node.layoutSource == .auto
      }
    )
  }

  @Test("pipeline layout JSON round-trips viewport and node positions")
  func pipelineLayoutJSONRoundTripsViewportAndNodePositions() throws {
    let layout = TaskBoardPolicyPipelineLayout(
      zoom: 1.25,
      offset: TaskBoardPolicyCanvasPoint(x: 320.4, y: 180.6),
      nodes: [
        TaskBoardPolicyPipelineNodeLayout(nodeId: "node-a", x: 40, y: 60, source: .manual)
      ]
    )

    let data = try JSONEncoder().encode(layout)
    let decoded = try JSONDecoder().decode(TaskBoardPolicyPipelineLayout.self, from: data)

    #expect(decoded.zoom == 1.25)
    #expect(decoded.offset == TaskBoardPolicyCanvasPoint(x: 320, y: 181))
    #expect(decoded.nodes == layout.nodes)
  }

  @Test("pipeline layout decodes legacy node-only payload")
  func pipelineLayoutDecodesLegacyNodeOnlyPayload() throws {
    let data = Data("""
      {"nodes":[{"nodeId":"node-a","x":40,"y":60,"source":"manual"}]}
      """.utf8)

    let decoded = try JSONDecoder().decode(TaskBoardPolicyPipelineLayout.self, from: data)

    #expect(decoded.zoom == 1)
    #expect(decoded.offset == .zero)
    #expect(
      decoded.nodes == [
        TaskBoardPolicyPipelineNodeLayout(nodeId: "node-a", x: 40, y: 60, source: .manual)
      ]
    )
  }
}
