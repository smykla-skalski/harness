import Foundation
import HarnessMonitorKit
import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

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

  func manualOCRPasteHubDocument() -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      revision: 1,
      mode: .enforced,
      nodes: [
        pipelineNode(
          id: "automation:manual-ocr-paste:source",
          title: "Manual OCR Paste",
          kind: TaskBoardPolicyPipelineNodeKind(
            kind: "action_step",
            actionId: "automation.manual_ocr_paste"
          ),
          automation: .canvasDefault(source: .manualOCRPaste),
          inputs: [],
          outputs: ["image"]
        ),
        pipelineNode(
          id: "automation:manual-ocr-paste:ocr",
          title: "OCR image",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "ocr_image"),
          automation: .canvasComponent(actions: [.ocrImage]),
          inputs: ["in"],
          outputs: ["text"]
        ),
        pipelineNode(
          id: "automation:manual-ocr-paste:hub",
          title: "Hub",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "hub"),
          inputs: ["in"],
          outputs: ["out_1", "out_2", "out_3"]
        ),
        pipelineNode(
          id: "automation:manual-ocr-paste:debug",
          title: "Open Debugging",
          kind: TaskBoardPolicyPipelineNodeKind(
            kind: "action_step",
            actionId: "dashboard.open_debugging"
          ),
          automation: .canvasComponent(actions: [.openDashboardDebugging]),
          inputs: ["in"],
          outputs: []
        ),
        pipelineNode(
          id: "automation:manual-ocr-paste:persist",
          title: "Persist OCR Result",
          kind: TaskBoardPolicyPipelineNodeKind(
            kind: "action_step",
            actionId: "ocr.persist_result"
          ),
          automation: .canvasComponent(
            actions: [.rememberRecentScan, .showFeedback, .recordMetadata],
            postprocessors: [.sourceSpecificTextCleanup, .persistResult, .auditEvent]
          ),
          inputs: ["in"],
          outputs: []
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge:manual-ocr-paste:ocr",
          fromNodeId: "automation:manual-ocr-paste:source",
          fromPort: "image",
          toNodeId: "automation:manual-ocr-paste:ocr",
          toPort: "in"
        ),
        TaskBoardPolicyPipelineEdge(
          id: "edge:manual-ocr-paste:hub",
          fromNodeId: "automation:manual-ocr-paste:ocr",
          fromPort: "text",
          toNodeId: "automation:manual-ocr-paste:hub",
          toPort: "in"
        ),
        TaskBoardPolicyPipelineEdge(
          id: "edge:manual-ocr-paste:debug",
          fromNodeId: "automation:manual-ocr-paste:hub",
          fromPort: "out_1",
          toNodeId: "automation:manual-ocr-paste:debug",
          toPort: "in"
        ),
        TaskBoardPolicyPipelineEdge(
          id: "edge:manual-ocr-paste:persist",
          fromNodeId: "automation:manual-ocr-paste:hub",
          fromPort: "out_2",
          toNodeId: "automation:manual-ocr-paste:persist",
          toPort: "in"
        ),
      ],
      groups: []
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
