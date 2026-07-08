import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard policy canvas selection preview")
struct DashboardPolicyCanvasSelectionPreviewTests {
  @Test("cached inactive canvas previews its document immediately")
  func cachedInactiveCanvasUsesImmediateSnapshot() {
    let active = makeCanvasSummary(canvasId: "active", document: makeDocument(revision: 1))
    let cached = makeCanvasSummary(canvasId: "cached", document: makeDocument(revision: 7))
    let workspace = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: active.canvasId,
      canvases: [active, cached]
    )

    let preview = DashboardPolicyCanvasSelectionPreview(
      workspace: workspace,
      selectedCanvasId: cached.canvasId
    )

    #expect(preview?.snapshot.activeCanvasId == cached.canvasId)
    #expect(preview?.snapshot.document?.revision == 7)
    #expect(preview?.showsLoadingPlaceholder == false)
  }

  @Test("uncached inactive canvas shows loading instead of stale active content")
  func uncachedInactiveCanvasShowsLoadingPlaceholder() {
    let active = makeCanvasSummary(canvasId: "active", document: makeDocument(revision: 1))
    let uncached = makeCanvasSummary(canvasId: "uncached", document: nil)
    let workspace = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: active.canvasId,
      canvases: [active, uncached]
    )

    let preview = DashboardPolicyCanvasSelectionPreview(
      workspace: workspace,
      selectedCanvasId: uncached.canvasId
    )

    #expect(preview?.snapshot.activeCanvasId == uncached.canvasId)
    #expect(preview?.snapshot.document == nil)
    #expect(preview?.showsLoadingPlaceholder == true)
  }

  @Test("active canvas selection does not create an override preview")
  func activeCanvasSelectionSkipsPreview() {
    let active = makeCanvasSummary(canvasId: "active", document: makeDocument(revision: 1))
    let workspace = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: active.canvasId,
      canvases: [active]
    )

    let preview = DashboardPolicyCanvasSelectionPreview(
      workspace: workspace,
      selectedCanvasId: active.canvasId
    )

    #expect(preview == nil)
  }

  private func makeCanvasSummary(
    canvasId: String,
    document: PolicyPipelineDocument?
  ) -> PolicyCanvasSummary {
    PolicyCanvasSummary(
      canvasId: canvasId,
      title: canvasId,
      revision: document?.revision ?? 0,
      mode: document?.mode ?? .draft,
      document: document,
      nodeCount: document?.nodes.count ?? 0,
      edgeCount: document?.edges.count ?? 0,
      groupCount: document?.groups.count ?? 0,
      updatedAt: "2026-05-31T00:00:00Z"
    )
  }

  private func makeDocument(revision: UInt64) -> PolicyPipelineDocument {
    PolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: [],
      layout: .init()
    )
  }
}
