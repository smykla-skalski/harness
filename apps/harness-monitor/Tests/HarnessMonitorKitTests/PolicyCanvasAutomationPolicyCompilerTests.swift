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

  @Test("review screenshot paste binding compiles OCR and extraction config")
  func reviewScreenshotPasteBindingCompilesOCRAndExtractionConfig() throws {
    var source = PolicyCanvasNode(
      id: "source-review-screenshot-paste",
      title: "Review Screenshot Paste",
      kind: .reviewScreenshotPaste,
      position: CGPoint(x: 20, y: 20)
    )
    var binding = TaskBoardPolicyPipelineAutomationBinding.canvasDefault(
      source: .reviewScreenshotPaste
    )
    binding.ocrConfiguration = TaskBoardPolicyPipelineOCRConfiguration(
      recognitionLevel: "fast",
      automaticallyDetectsLanguage: false,
      usesLanguageCorrection: false
    )
    binding.reviewPullRequestExtraction = TaskBoardPolicyPipelineReviewPullRequestExtraction(
      repositoryMode: "policyRepositories",
      policyRepositories: ["kong/kuma"],
      numberMemoryEnabled: false,
      resultScope: "failing",
      failureSignalMode: "visualScreenshot",
      outputFormat: "ownerRepoNumber",
      autoCopy: false,
      showSheet: true
    )
    source.automationBinding = binding

    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(nodes: [source], edges: [])
    let policy = try #require(compilation.policies.first)

    #expect(policy.eventSource == .reviewScreenshotPaste)
    #expect(policy.match.contentKinds == [.image])
    #expect(policy.actions.contains(.ocrImage))
    #expect(policy.actions.contains(.resolveReviewPullRequests))
    #expect(policy.actions.contains(.copyReviewPullRequestList))
    #expect(policy.ocrConfiguration?.recognitionLevel == .fast)
    #expect(policy.ocrConfiguration?.automaticallyDetectsLanguage == false)
    #expect(policy.reviewPullRequestExtraction?.repositoryMode == .policyRepositories)
    #expect(policy.reviewPullRequestExtraction?.policyRepositories == ["kong/kuma"])
    #expect(policy.reviewPullRequestExtraction?.resultScope == .failing)
    #expect(policy.reviewPullRequestExtraction?.failureSignalMode == .visualScreenshot)
    #expect(policy.reviewPullRequestExtraction?.outputFormat == .ownerRepoNumber)
    #expect(policy.reviewPullRequestExtraction?.autoCopy == false)
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

  @Test("dry run gate marks only review text paste policies that route to it")
  func dryRunGateMarksOnlyReviewTextPastePoliciesThatRouteToIt() throws {
    var dryRunSource = PolicyCanvasNode(
      id: "source-review-text-paste",
      title: "Review Text Paste",
      kind: .source,
      position: CGPoint(x: 20, y: 20)
    )
    dryRunSource.automationBinding = .canvasDefault(source: .manualReviewTextPaste)
    let dryRunGate = PolicyCanvasNode(
      id: "dry-run-pasted-approvals",
      title: "Dry-run gate",
      kind: .dryRunGate,
      position: CGPoint(x: 280, y: 20)
    )
    var liveSource = PolicyCanvasNode(
      id: "source-review-text-paste-live",
      title: "Review Text Paste live",
      kind: .source,
      position: CGPoint(x: 20, y: 220)
    )
    liveSource.automationBinding = .canvasDefault(source: .manualReviewTextPaste)

    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(
      nodes: [dryRunSource, dryRunGate, liveSource],
      edges: [
        edge(
          id: "edge-review-paste-dry-run",
          from: dryRunSource.id,
          to: dryRunGate.id,
          label: "preview only"
        )
      ]
    )

    let dryRunPolicy = try #require(compilation.policy(compiledFrom: dryRunSource.id))
    let livePolicy = try #require(compilation.policy(compiledFrom: liveSource.id))
    #expect(dryRunPolicy.eventSource == .manualReviewTextPaste)
    #expect(dryRunPolicy.isDryRun)
    #expect(dryRunPolicy.actions.contains(.previewReviewApprovals))
    #expect(dryRunPolicy.actions.contains(.promptReviewApprovals))
    #expect(!livePolicy.isDryRun)
  }

  @Test("pipeline document compiles pasted PR dry run policy")
  func pipelineDocumentCompilesPastedPRDryRunPolicy() throws {
    let document = TaskBoardPolicyPipelineDocument(
      revision: 1,
      mode: .enforced,
      nodes: [
        pipelineNode(
          id: "automation:review-text-paste:source",
          title: "Review Text Paste",
          kind: TaskBoardPolicyPipelineNodeKind(
            kind: "action_step",
            actionId: "automation.review_text_paste"
          ),
          automation: .canvasDefault(source: .manualReviewTextPaste),
          inputs: [],
          outputs: ["default"]
        ),
        pipelineNode(
          id: "automation:review-text-paste:dry-run",
          title: "Dry-run gate",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate"),
          inputs: ["in"],
          outputs: []
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge:review-text-paste:dry-run",
          fromNodeId: "automation:review-text-paste:source",
          fromPort: "default",
          toNodeId: "automation:review-text-paste:dry-run",
          toPort: "in"
        )
      ],
      groups: []
    )

    let compilation = PolicyCanvasAutomationPolicyCompiler.compile(document: document)
    let policy = try #require(compilation.policies.first)

    #expect(compilation.policies.count == 1)
    #expect(policy.eventSource == .manualReviewTextPaste)
    #expect(policy.isDryRun)
    #expect(policy.actions.contains(.extractGitHubPullRequests))
    #expect(policy.actions.contains(.previewReviewApprovals))
    #expect(policy.actions.contains(.promptReviewApprovals))
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

  @Test("automation center keeps canvas and review policies out of JSON persistence")
  func automationCenterKeepsCanvasAndReviewPoliciesOutOfJSONPersistence() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("policies.json")
    let center = AutomationPolicyCenter(fileURL: fileURL)
    let canvasPolicy = AutomationPolicy(
      id: "canvas.reviewScreenshotPaste.source",
      name: "Canvas Screenshot Policy",
      eventSource: .reviewScreenshotPaste,
      isEnabled: true,
      priority: 1,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [],
      actions: [.ocrImage],
      postprocessors: [.auditEvent],
      ocrConfiguration: AutomationPolicyOCRConfiguration(),
      reviewPullRequestExtraction: ReviewPullRequestExtractionConfiguration()
    )

    center.replaceCanvasPolicies([canvasPolicy])
    center.createPolicy(for: .reviewScreenshotPaste)

    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let persisted = try decoder.decode(AutomationPolicyDocument.self, from: data)

    #expect(center.document.hasCanvasPolicies)
    #expect(persisted.canvasPolicies.isEmpty)
    #expect(persisted.policies.allSatisfy { $0.eventSource != .reviewScreenshotPaste })
    #expect(persisted.policies.allSatisfy { $0.eventSource != .manualReviewTextPaste })
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

}
