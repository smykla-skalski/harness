import Foundation
import HarnessMonitorKit
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas automation policy compiler")
@MainActor
struct PolicyCanvasAutomationPolicyCompilerTests {
  @Test("canvas source graph compiles to an enforceable clipboard OCR policy")
  func canvasSourceGraphCompilesToEnforceableClipboardOCRPolicy() throws {
    let source = PolicyCanvasNode(
      id: "source-clipboard",
      title: "Clipboard image OCR",
      kind: .source,
      position: CGPoint(x: 20, y: 20)
    )
    let transform = PolicyCanvasNode(
      id: "action-ocr-feedback",
      title: "OCR images with haptic feedback",
      kind: .transform,
      position: CGPoint(x: 260, y: 20)
    )
    let decision = PolicyCanvasNode(
      id: "decision-persist",
      title: "Remember recent scans and audit metadata",
      kind: .decision,
      position: CGPoint(x: 520, y: 20)
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(
      nodes: [source, transform, decision],
      edges: [
        edge(
          id: "edge-source-transform",
          from: source.id,
          to: transform.id,
          label: "image"
        ),
        edge(
          id: "edge-transform-decision",
          from: transform.id,
          to: decision.id,
          label: "persist result"
        ),
      ]
    )

    let policy = try #require(compilation.policies.first)
    #expect(policy.id == "canvas.clipboard.source-clipboard")
    #expect(policy.eventSource == .clipboard)
    #expect(policy.isEnabled)
    #expect(policy.match.contentKinds == [.image])
    #expect(policy.preprocessors.contains(.respectPasteboardPrivacy))
    #expect(policy.preprocessors.contains(.skipSensitiveMarkers))
    #expect(policy.preprocessors.contains(.dedupeByFingerprint))
    #expect(policy.actions.contains(.ocrImage))
    #expect(policy.actions.contains(.rememberRecentScan))
    #expect(policy.actions.contains(.showFeedback))
    #expect(policy.actions.contains(.recordMetadata))
    #expect(policy.postprocessors.contains(.sourceSpecificTextCleanup))
    #expect(policy.postprocessors.contains(.persistResult))
    #expect(policy.postprocessors.contains(.auditEvent))
  }

  @Test("explicit source automation binding compiles without title heuristics")
  func explicitSourceAutomationBindingCompilesWithoutTitleHeuristics() throws {
    var source = PolicyCanvasNode(
      id: "source-copied-assets",
      title: "Copied assets intake",
      kind: .source,
      position: CGPoint(x: 20, y: 20)
    )
    var binding = TaskBoardPolicyPipelineAutomationBinding.canvasDefault(source: .clipboard)
    binding.priority = 7
    binding.actions.append(AutomationPolicyAction.openDashboardDebugging.rawValue)
    binding.sourceAppMode = AutomationSourceAppMode.allowedOnly.rawValue
    binding.allowedBundleIdentifiers = ["com.example.notes"]
    source.automationBinding = binding

    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(nodes: [source], edges: [])

    let policy = try #require(compilation.policies.first)
    #expect(policy.id == "canvas.clipboard.source-copied-assets")
    #expect(policy.name == "Copied assets intake")
    #expect(policy.eventSource == .clipboard)
    #expect(policy.priority == 7)
    #expect(policy.match.contentKinds == [.image])
    #expect(policy.actions.contains(.ocrImage))
    #expect(policy.actions.contains(.openDashboardDebugging))
    #expect(policy.match.sourceAppFilter.mode == .allowedOnly)
    #expect(policy.match.sourceAppFilter.allowedBundleIdentifiers == ["com.example.notes"])
  }

  @Test("compiled policy lookup uses exact source IDs when source slugs collide")
  func compiledPolicyLookupUsesExactSourceIDsWhenSourceSlugsCollide() throws {
    let dottedSource = PolicyCanvasNode(
      id: "source.clipboard",
      title: "Clipboard dotted source",
      kind: .source,
      position: CGPoint(x: 20, y: 20)
    )
    let dashedSource = PolicyCanvasNode(
      id: "source-clipboard",
      title: "Clipboard dashed source",
      kind: .source,
      position: CGPoint(x: 20, y: 120)
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(
      nodes: [dashedSource, dottedSource],
      edges: []
    )

    let dottedPolicy = try #require(compilation.policy(compiledFrom: dottedSource.id))
    let dashedPolicy = try #require(compilation.policy(compiledFrom: dashedSource.id))
    #expect(compilation.policies.count == 2)
    #expect(Set(compilation.policies.map(\.id)).count == 2)
    #expect(dottedPolicy.name == "Clipboard dotted source")
    #expect(dashedPolicy.name == "Clipboard dashed source")
    #expect(dottedPolicy.id != dashedPolicy.id)
    #expect(compilation.policy(compiledFrom: "source_clipboard") == nil)
  }

  @Test("automation palette components configure connected source policies")
  func automationPaletteComponentsConfigureConnectedSourcePolicies() throws {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.createAutomationNode(item: .clipboardMonitor, at: CGPoint(x: 100, y: 100))
    viewModel.createAutomationNode(item: .contentText, at: CGPoint(x: 360, y: 100))
    viewModel.createAutomationNode(item: .sourceApplicationFilter, at: CGPoint(x: 620, y: 100))
    viewModel.createAutomationNode(item: .openDebugging, at: CGPoint(x: 880, y: 100))
    viewModel.createAutomationNode(item: .persistResult, at: CGPoint(x: 1140, y: 100))

    let source = try #require(viewModel.nodes.first { $0.title == "Clipboard Monitor" })
    let text = try #require(viewModel.nodes.first { $0.title == "Text" })
    let appFilter = try #require(viewModel.nodes.first { $0.title == "Source App Filter" })
    let openDebugging = try #require(viewModel.nodes.first { $0.title == "Open Debugging" })
    let persist = try #require(viewModel.nodes.first { $0.title == "Persist OCR Result" })

    let appFilterIndex = try #require(viewModel.nodes.firstIndex { $0.id == appFilter.id })
    var appFilterBinding = try #require(viewModel.nodes[appFilterIndex].automationBinding)
    appFilterBinding.sourceAppMode = AutomationSourceAppMode.allowedOnly.rawValue
    appFilterBinding.allowedBundleIdentifiers = ["com.example.editor"]
    viewModel.nodes[appFilterIndex].automationBinding = appFilterBinding

    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(
      nodes: viewModel.nodes,
      edges: [
        edge(id: "edge-source-text", from: source.id, to: text.id, label: "event"),
        edge(id: "edge-text-filter", from: text.id, to: appFilter.id, label: "content"),
        edge(id: "edge-filter-open", from: appFilter.id, to: openDebugging.id, label: "allowed"),
        edge(id: "edge-open-persist", from: openDebugging.id, to: persist.id, label: "after"),
      ]
    )

    let policy = try #require(compilation.policy(compiledFrom: source.id))
    #expect(policy.eventSource == .clipboard)
    #expect(policy.match.contentKinds.contains(.image))
    #expect(policy.match.contentKinds.contains(.text))
    #expect(policy.preprocessors.contains(.filterSourceApplications))
    #expect(policy.actions.contains(.openDashboardDebugging))
    #expect(policy.postprocessors.contains(.persistResult))
    #expect(policy.match.sourceAppFilter.mode == .allowedOnly)
    #expect(policy.match.sourceAppFilter.allowedBundleIdentifiers == ["com.example.editor"])
  }

  @Test("automation component nodes do not compile standalone policies")
  func automationComponentNodesDoNotCompileStandalonePolicies() throws {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.createAutomationNode(item: .ocrImages, at: CGPoint(x: 100, y: 100))
    viewModel.createAutomationNode(item: .auditEvent, at: CGPoint(x: 360, y: 100))

    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(
      nodes: viewModel.nodes,
      edges: []
    )

    #expect(compilation.policies.isEmpty)
    #expect(compilation.diagnostics.contains { $0.id == "missing-source" })
  }

  @Test("automation center enforces the policies compiled from canvas")
  func automationCenterEnforcesPoliciesCompiledFromCanvas() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = AutomationPolicyCenter(
      fileURL: directory.appendingPathComponent("policies.json")
    )
    let stalePolicy = AutomationPolicy(
      id: "canvas.clipboard.stale",
      name: "Stale Canvas Policy",
      eventSource: .clipboard,
      isEnabled: true,
      priority: 1,
      match: AutomationPolicyMatch(contentKinds: [.text]),
      preprocessors: [],
      actions: [.recordMetadata],
      postprocessors: [.auditEvent]
    )
    center.replaceCanvasPolicies([stalePolicy])

    let source = PolicyCanvasNode(
      id: "source-clipboard",
      title: "Clipboard image OCR allow only com.example.notes",
      kind: .source,
      position: CGPoint(x: 20, y: 20)
    )
    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(nodes: [source], edges: [])
    center.replaceCanvasPolicies(compilation.policies)

    let policy = try #require(center.policy(id: "canvas.clipboard.source-clipboard"))
    let decision = center.decision(
      for: .clipboard,
      contentKinds: [.image],
      sourceApplication: AutomationSourceApplication(
        bundleIdentifier: "com.example.notes",
        localizedName: "Example Notes",
        processIdentifier: 200
      ),
      accessBehaviorDescription: "alwaysAllow"
    )

    #expect(center.policy(id: stalePolicy.id) == nil)
    #expect(policy.match.sourceAppFilter.mode == .allowedOnly)
    #expect(decision.isAllowed)
    #expect(decision.policy.id == policy.id)
    #expect(decision.shouldOCRImages)
    #expect(center.isClipboardMonitorEnabled)
  }

  @Test("automation center clears stale canvas policies when canvas compiles none")
  func automationCenterClearsStaleCanvasPoliciesWhenCanvasCompilesNone() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = AutomationPolicyCenter(
      fileURL: directory.appendingPathComponent("policies.json")
    )
    let stalePolicy = AutomationPolicy(
      id: "canvas.clipboard.stale",
      name: "Stale Canvas Policy",
      eventSource: .clipboard,
      isEnabled: true,
      priority: 1,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [],
      actions: [.ocrImage],
      postprocessors: [.auditEvent]
    )

    center.replaceCanvasPolicies([stalePolicy])
    #expect(center.document.hasCanvasPolicies)
    center.replaceCanvasPolicies([])

    #expect(!center.document.hasCanvasPolicies)
    #expect(center.policy(id: stalePolicy.id) == nil)
    #expect(!center.isClipboardMonitorEnabled)
  }

  @Test("automation policies sort deterministic ties by identifier")
  func automationPoliciesSortDeterministicTiesByIdentifier() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = AutomationPolicyCenter(
      fileURL: directory.appendingPathComponent("policies.json")
    )
    let laterPolicy = tiedClipboardPolicy(id: "synthetic.clipboard.b")
    let earlierPolicy = tiedClipboardPolicy(id: "synthetic.clipboard.a")

    center.replacePolicy(laterPolicy)
    center.replacePolicy(earlierPolicy)

    let orderedIDs = center.document.policies(for: .clipboard).prefix(2).map(\.id)
    let decision = center.decision(
      for: .clipboard,
      contentKinds: [.image],
      accessBehaviorDescription: "alwaysAllow"
    )

    #expect(orderedIDs == ["synthetic.clipboard.a", "synthetic.clipboard.b"])
    #expect(decision.policy.id == "synthetic.clipboard.a")
  }

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

  private func edge(id: String, from: String, to: String, label: String) -> PolicyCanvasEdge {
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

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PolicyCanvasAutomationPolicyCompilerTests-\(UUID().uuidString)",
        isDirectory: true
      )
  }

  private func tiedClipboardPolicy(id: String) -> AutomationPolicy {
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
