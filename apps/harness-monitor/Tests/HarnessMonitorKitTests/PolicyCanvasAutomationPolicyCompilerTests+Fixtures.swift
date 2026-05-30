import Foundation
import HarnessMonitorKit
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasAutomationPolicyCompilerTests {
  @Test("compiler assigns unique IDs and maps policies by source node ID")
  func compilerAssignsUniqueIDsAndMapsPoliciesBySourceNodeID() throws {
    let firstSource = PolicyCanvasNode(
      id: "source-a",
      title: "Clipboard image OCR",
      kind: .source,
      position: CGPoint(x: 20, y: 20)
    )
    let secondSource = PolicyCanvasNode(
      id: "source a",
      title: "Clipboard text metadata",
      kind: .source,
      position: CGPoint(x: 260, y: 20)
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(
      nodes: [firstSource, secondSource],
      edges: []
    )
    let firstPolicy = try #require(compilation.policy(compiledFrom: firstSource.id))
    let secondPolicy = try #require(compilation.policy(compiledFrom: secondSource.id))

    #expect(compilation.policies.count == 2)
    #expect(Set(compilation.policies.map(\.id)).count == 2)
    #expect(firstPolicy.id == "canvas.clipboard.source-a")
    #expect(secondPolicy.id.hasPrefix("canvas.clipboard.source-a-"))
    #expect(secondPolicy.name == "Clipboard text metadata")
  }

  @Test("view model caches automation compilation until graph inputs change")
  func viewModelCachesAutomationCompilationUntilGraphInputsChange() throws {
    let source = PolicyCanvasNode(
      id: "source-clipboard",
      title: "Clipboard image OCR",
      kind: .source,
      position: CGPoint(x: 20, y: 20)
    )
    let viewModel = PolicyCanvasViewModel(nodes: [source], groups: [], edges: [])

    let firstCompilation = viewModel.automationPolicyCompilation
    let secondCompilation = viewModel.automationPolicyCompilation

    viewModel.nodes[0].title = "Clipboard text metadata"
    #expect(viewModel.automationPolicyCompilation == firstCompilation)
    viewModel.refreshAutomationPolicyCompilation()
    let thirdCompilation = viewModel.automationPolicyCompilation

    #expect(firstCompilation == secondCompilation)
    #expect(thirdCompilation != firstCompilation)
    #expect(thirdCompilation.policies.first?.match.contentKinds.contains(.text) == true)
  }

  func edge(id: String, from: String, to: String, label: String) -> PolicyCanvasEdge {
    PolicyCanvasEdge(
      id: id,
      source: PolicyCanvasPortEndpoint(
        nodeID: from,
        portID: "output-event",
        kind: .output
      ),
      target: PolicyCanvasPortEndpoint(
        nodeID: to,
        portID: "input-event",
        kind: .input
      ),
      label: label
    )
  }

  func pipelineNode(
    id: String,
    title: String,
    kind: TaskBoardPolicyPipelineNodeKind,
    automation: TaskBoardPolicyPipelineAutomationBinding? = nil,
    inputs: [String],
    outputs: [String]
  ) -> TaskBoardPolicyPipelineNode {
    TaskBoardPolicyPipelineNode(
      id: id,
      title: title,
      kind: kind,
      automation: automation,
      inputs: inputs.map { TaskBoardPolicyPipelinePort(id: $0, title: $0) },
      outputs: outputs.map { TaskBoardPolicyPipelinePort(id: $0, title: $0) }
    )
  }

  func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PolicyCanvasAutomationPolicyCompilerTests-\(UUID().uuidString)",
        isDirectory: true
      )
  }

  func tiedClipboardPolicy(id: String) -> AutomationPolicy {
    AutomationPolicy(
      id: id,
      name: "Synthetic Clipboard Policy",
      eventSource: .clipboard,
      isEnabled: true,
      priority: 1,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [],
      actions: [.recordMetadata],
      postprocessors: [.auditEvent]
    )
  }
}
