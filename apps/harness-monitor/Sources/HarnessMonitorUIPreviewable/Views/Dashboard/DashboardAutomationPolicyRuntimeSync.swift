import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
import SwiftUI

extension View {
  public func dashboardAutomationPolicyRuntimeSync(
    workspace: TaskBoardPolicyCanvasWorkspace?,
    activeDocument: TaskBoardPolicyPipelineDocument?,
    policyCenter: AutomationPolicyCenter = .shared
  ) -> some View {
    modifier(
      DashboardAutomationPolicyRuntimeSyncModifier(
        workspace: workspace,
        activeDocument: activeDocument,
        policyCenter: policyCenter
      )
    )
  }
}

@MainActor
enum DashboardAutomationPolicyRuntimeSynchronizer {
  static func synchronizeEnforcedCanvasAutomationPolicies(
    policyCenter: AutomationPolicyCenter,
    workspace: TaskBoardPolicyCanvasWorkspace?,
    activeDocument: TaskBoardPolicyPipelineDocument?
  ) {
    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: workspace,
      activeDocument: activeDocument
    )
    let compiledPolicies = compilation.policies.map(AutomationPolicy.init)
    guard policyCenter.document.canvasPolicies != compiledPolicies else {
      return
    }
    guard !compiledPolicies.isEmpty || policyCenter.document.hasCanvasPolicies else {
      return
    }
    policyCenter.replaceCanvasPolicies(compiledPolicies)
  }
}

private struct DashboardAutomationPolicyRuntimeSyncModifier: ViewModifier {
  let workspace: TaskBoardPolicyCanvasWorkspace?
  let activeDocument: TaskBoardPolicyPipelineDocument?
  let policyCenter: AutomationPolicyCenter

  private var syncID: DashboardAutomationPolicyRuntimeSyncID {
    DashboardAutomationPolicyRuntimeSyncID(
      workspace: workspace,
      activeDocument: activeDocument
    )
  }

  func body(content: Content) -> some View {
    content
      .task(id: syncID) {
        DashboardAutomationPolicyRuntimeSynchronizer
          .synchronizeEnforcedCanvasAutomationPolicies(
            policyCenter: policyCenter,
            workspace: workspace,
            activeDocument: activeDocument
          )
      }
  }
}

private struct DashboardAutomationPolicyRuntimeSyncID: Equatable {
  let activeCanvasId: String?
  let canvasFingerprints: [CanvasFingerprint]
  let activeDocumentFingerprint: DocumentFingerprint?

  init(
    workspace: TaskBoardPolicyCanvasWorkspace?,
    activeDocument: TaskBoardPolicyPipelineDocument?
  ) {
    activeCanvasId = workspace?.activeCanvasId
    canvasFingerprints =
      workspace?.canvases.map {
        CanvasFingerprint(summary: $0)
      } ?? []
    activeDocumentFingerprint = activeDocument.map(DocumentFingerprint.init(document:))
  }

  struct CanvasFingerprint: Equatable {
    let canvasId: String
    let revision: UInt64
    let mode: TaskBoardPolicyPipelineMode
    let embeddedDocumentFingerprint: DocumentFingerprint?

    init(summary: TaskBoardPolicyCanvasSummary) {
      canvasId = summary.canvasId
      revision = summary.revision
      mode = summary.mode
      embeddedDocumentFingerprint = summary.document.map(DocumentFingerprint.init(document:))
    }
  }

  struct DocumentFingerprint: Equatable {
    let policyTraceIds: [String]
    let revision: UInt64
    let mode: TaskBoardPolicyPipelineMode
    let nodeCount: Int
    let edgeCount: Int
    let groupCount: Int

    init(document: TaskBoardPolicyPipelineDocument) {
      policyTraceIds = document.policyTraceIds
      revision = document.revision
      mode = document.mode
      nodeCount = document.nodes.count
      edgeCount = document.edges.count
      groupCount = document.groups.count
    }
  }
}
