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
}
