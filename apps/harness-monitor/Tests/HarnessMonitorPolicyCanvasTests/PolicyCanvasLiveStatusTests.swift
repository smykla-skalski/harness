import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

/// Phase 3 live anchor: the persistent LIVE/DRAFT signal derived from the daemon
/// audit (active enforced revision + mode) versus the draft being edited, plus
/// the `captureLiveAudit(_:)` wiring on the document-apply path.
@Suite("Policy canvas live status")
@MainActor
struct PolicyCanvasLiveStatusTests {
  @Test("Clean draft matching the enforced active revision reads as LIVE")
  func liveWhenCleanAndEnforcedRevisionMatches() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.backingDocument = draftDocument(revision: 5)
    viewModel.latestAudit = liveAudit(revision: 5, mode: .enforced)

    #expect(viewModel.liveStatus == .live(revision: 5, publishedAt: nil))
    #expect(viewModel.liveStatus.isLive)
  }

  @Test("Unsaved edits flip a live canvas back to DRAFT")
  func draftWhenDirty() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.backingDocument = draftDocument(revision: 5)
    viewModel.latestAudit = liveAudit(revision: 5, mode: .enforced)
    viewModel.markDocumentDirty()

    #expect(viewModel.liveStatus == .draft(liveRevision: 5))
  }

  @Test("A draft revision ahead of the enforced revision reads as DRAFT")
  func draftWhenRevisionAheadOfLive() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.backingDocument = draftDocument(revision: 6)
    viewModel.latestAudit = liveAudit(revision: 5, mode: .enforced)

    #expect(viewModel.liveStatus == .draft(liveRevision: 5))
  }

  @Test("A never-enforced canvas reads as DRAFT with no live revision")
  func draftWithoutLiveWhenNotEnforced() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.backingDocument = draftDocument(revision: 5)
    viewModel.latestAudit = liveAudit(revision: 5, mode: .dryRun)

    #expect(viewModel.liveStatus == .draft(liveRevision: nil))
  }

  @Test("Global enforcement disabled prevents an enforced canvas reading as LIVE")
  func draftWhenGlobalEnforcementDisabled() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.backingDocument = draftDocument(revision: 5)
    viewModel.captureLiveAudit(
      liveAudit(revision: 5, mode: .enforced, globalPolicyEnforcementEnabled: false)
    )

    #expect(viewModel.liveStatus == .draft(liveRevision: nil))
    #expect(!viewModel.liveStatus.isLive)
  }

  @Test("Workspace capture adds live published timestamp")
  func liveStatusCarriesPublishedTimestamp() throws {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.backingDocument = draftDocument(revision: 5)
    viewModel.captureLiveAudit(liveAudit(revision: 5, mode: .enforced))
    viewModel.captureLiveWorkspace(
      liveWorkspace(canvasId: "canvas-live", revision: 5, updatedAt: "2026-06-20T08:15:30Z"),
      activeCanvasId: "canvas-live"
    )

    guard case .live(revision: 5, let publishedAtCandidate) = viewModel.liveStatus else {
      Issue.record("Expected live status")
      return
    }
    let publishedAt = try #require(publishedAtCandidate)
    #expect(publishedAt == PolicyCanvasLiveStatusDateFormatting.date(from: "2026-06-20T08:15:30Z"))
  }

  @Test("No backing document or audit reads as no policy")
  func noPolicyWhenNothingLoaded() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])

    #expect(viewModel.liveStatus == .noPolicy)
    #expect(!viewModel.liveStatus.isLive)
  }

  @Test("applyDocument captures the audit so the anchor resolves end to end")
  func applyDocumentCapturesAuditForAnchor() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.applyDocument(
      document: draftDocument(revision: 9),
      simulation: nil,
      audit: liveAudit(revision: 9, mode: .enforced)
    )

    #expect(viewModel.latestAudit != nil)
    #expect(viewModel.liveStatus == .live(revision: 9, publishedAt: nil))
  }

  @Test("A nil audit republish never blanks an existing anchor")
  func nilAuditPreservesAnchor() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestAudit = liveAudit(revision: 5, mode: .enforced)

    viewModel.captureLiveAudit(nil)

    #expect(viewModel.latestAudit != nil)
  }

  private func draftDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: [],
      layout: TaskBoardPolicyPipelineLayout(nodes: []),
      policyTraceIds: []
    )
  }

  private func liveAudit(
    revision: UInt64,
    mode: TaskBoardPolicyPipelineMode,
    globalPolicyEnforcementEnabled: Bool = true
  ) -> TaskBoardPolicyPipelineAuditSummary {
    TaskBoardPolicyPipelineAuditSummary(
      activeRevision: revision,
      mode: mode,
      globalPolicyEnforcementEnabled: globalPolicyEnforcementEnabled,
      validation: TaskBoardPolicyPipelineValidation(isValid: true)
    )
  }

  private func liveWorkspace(
    canvasId: String,
    revision: UInt64,
    updatedAt: String
  ) -> TaskBoardPolicyCanvasWorkspace {
    TaskBoardPolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: canvasId,
      canvases: [
        TaskBoardPolicyCanvasSummary(
          canvasId: canvasId,
          title: "Live",
          revision: revision,
          mode: .enforced,
          document: draftDocument(revision: revision),
          nodeCount: 0,
          edgeCount: 0,
          groupCount: 0,
          updatedAt: updatedAt
        )
      ],
      globalPolicyEnforcementEnabled: true
    )
  }
}
