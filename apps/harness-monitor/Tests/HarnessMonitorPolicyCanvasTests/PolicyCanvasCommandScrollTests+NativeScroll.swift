import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

extension PolicyCanvasCommandScrollTests {
  @MainActor
  @Test("switching to the pasted PR dry-run canvas recenters the native viewport")
  func switchingToPastedPRDryRunCanvasRecentersTheNativeViewport() async throws {
    let frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: TaskBoardPolicyPipelineDocument(
        revision: 1,
        mode: .draft,
        nodes: [],
        edges: [],
        groups: []
      ),
      simulation: nil,
      audit: nil,
      activeCanvasId: "default-canvas"
    )
    let host = NSHostingView(
      rootView: PolicyCanvasViewportSwitchTestHost(viewModel: viewModel)
    )
    let window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    let pastedDocument = policyCanvasPastedPRDryRunDocument()

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    host.frame = frame
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    viewModel.applyDocument(
      document: pastedDocument,
      simulation: nil,
      audit: nil,
      activeCanvasId: "pasted-pr-canvas",
      forceDocumentReload: true
    )

    #expect(
      await waitUntil {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard
          let scrollView = descendant(
            of: host,
            as: PolicyCanvasNativeScrollView.self
          )
        else {
          return false
        }
        return scrollView.contentView.bounds.width > 1
          && scrollView.contentView.bounds.height > 1
      }
    )

    let scrollView = try #require(descendant(of: host, as: PolicyCanvasNativeScrollView.self))
    let viewportSize = scrollView.bounds.size
    let routeOutput = PolicyCanvasRouteWorkerOutput.fallback(
      for: PolicyCanvasRouteWorkerInput(
        graphGeneration: viewModel.routeComputationGeneration,
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        fontScale: 1,
        routingHints: viewModel.routingHints,
        algorithmSelection: viewModel.algorithmSelection
      )
    )
    let expectedZoom = min(
      viewModel.zoom,
      viewModel.fittedInitialZoom(for: viewportSize, contentBounds: routeOutput.visibleBounds)
    )
