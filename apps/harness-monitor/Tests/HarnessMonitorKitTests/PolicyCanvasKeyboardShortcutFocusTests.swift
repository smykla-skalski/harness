import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas keyboard shortcut focus")
@MainActor
struct PolicyCanvasKeyboardShortcutFocusTests {
  @Test("native node selection requests keyboard focus for canvas shortcuts")
  func nativeNodeSelectionRequestsKeyboardFocus() throws {
    let focusedComponent = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let viewModel = PolicyCanvasViewModel.sample()
    var focusRequestCount = 0
    let snapshot = hostedSnapshot(
      viewModel: viewModel,
      focusedComponent: focusedComponent,
      requestKeyboardFocus: {
        focusRequestCount += 1
      }
    )
    let state = PolicyCanvasViewportHostedState(snapshot: snapshot)
    let scrollView = PolicyCanvasNativeScrollView()
    let frame = CGRect(x: 0, y: 0, width: 900, height: 700)
    scrollView.frame = frame

    let window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    window.contentView = scrollView
    scrollView.ensureDocumentRoot(state: state, size: snapshot.contentSize)
    window.layoutIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let documentView = try #require(scrollView.documentView as? PolicyCanvasNativeDocumentView)
    let node = try #require(viewModel.nodes.first)
    let workspacePoint = CGPoint(
      x: state.workspaceLayout.contentOrigin.x + node.position.x + PolicyCanvasLayout.nodeSize.width
        / 2,
      y: state.workspaceLayout.contentOrigin.y + node.position.y + PolicyCanvasLayout.nodeSize
        .height / 2
    )
    let event = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: documentView.convert(workspacePoint, to: nil),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
      )
    )

    #expect(documentView.routeMouseDown(event))
    #expect(viewModel.selection == .node(node.id))
    #expect(focusRequestCount == 1)
  }

  @Test("canvas root bridges native clicks into the SwiftUI shortcut host")
  func sourceContractsBridgeNativeFocusIntoShortcutHost() throws {
    let viewSource = try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasView.swift")
    let layoutSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+Layout.swift")
    let shortcutSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+Shortcuts.swift")
    let powerEditSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasPowerEditShortcuts.swift"
    )
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(viewSource.contains("@FocusState private var canvasKeyboardFocusedState: Bool"))
    #expect(viewSource.contains(".focusable()"))
    #expect(viewSource.contains(".focusEffectDisabled()"))
    #expect(viewSource.contains(".focused($canvasKeyboardFocusedState)"))
    #expect(viewSource.contains("func requestCanvasKeyboardFocus()"))
    #expect(viewSource.contains("canvasKeyboardFocusedState = true"))
    #expect(viewSource.contains(".onChange(of: sceneFocusEnabled"))
    #expect(layoutSource.contains("requestKeyboardFocus: requestCanvasKeyboardFocus"))
    #expect(shortcutSource.contains(".disabled(!sceneFocusEnabled || focusedField != nil)"))
    #expect(
      shortcutSource.contains(
        ".disabled(!sceneFocusEnabled || focusedField != nil || currentEditSheet == nil)")
    )
    #expect(powerEditSource.contains("let isEnabled: Bool"))
    #expect(powerEditSource.contains("guard isEnabled, focusedField == nil else"))
    #expect(coordinatorSource.contains("let requestKeyboardFocus: @MainActor () -> Void"))
    #expect(coordinatorSource.contains("hostedState.snapshot.requestKeyboardFocus()"))
    #expect(coordinatorSource.contains("rootView.state.snapshot.requestKeyboardFocus()"))
  }

  @Test(
    "canvas restores keyboard focus after transient UI closes or the route becomes visible again")
  func sourceContractsRestoreKeyboardFocusAfterTransientUIEnds() throws {
    let viewSource = try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasView.swift")

    #expect(viewSource.contains("func scheduleCanvasKeyboardFocusRestoreIfNeeded()"))
    #expect(viewSource.contains("guard sceneFocusEnabled"))
    #expect(viewSource.contains("!searchPaletteVisible"))
    #expect(viewSource.contains("presentedEditSheet == nil"))
    #expect(viewSource.contains("focusedField == nil"))
    #expect(viewSource.contains("await Task.yield()"))
    #expect(viewSource.contains(".onChange(of: searchPaletteVisible, initial: false)"))
    #expect(viewSource.contains(".onChange(of: presentedEditSheet, initial: false)"))
    #expect(viewSource.contains("if newValue {"))
    #expect(viewSource.contains("scheduleCanvasKeyboardFocusRestoreIfNeeded()"))
  }

  private func previewableSourceFile(named path: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(path)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func hostedSnapshot(
    viewModel: PolicyCanvasViewModel = PolicyCanvasViewModel.sample(),
    focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding,
    requestKeyboardFocus: @escaping @MainActor () -> Void = {}
  ) -> PolicyCanvasViewportHostedSnapshot {
    let routeOutput = PolicyCanvasRouteWorkerOutput.fallback(
      for: PolicyCanvasRouteWorkerInput(
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        fontScale: 1
      )
    )
    return PolicyCanvasViewportHostedSnapshot(
      viewModel: viewModel,
      focusedComponent: focusedComponent,
      edges: viewModel.edges,
      routes: routeOutput.routes,
      labelPositions: routeOutput.labelPositions,
      accessibilityLabelsByEdgeID: routeOutput.accessibilityEdgeLabelsByID,
      accessibilityNodeEntries: routeOutput.accessibilityNodeEntries,
      accessibilityEdgeEntries: routeOutput.accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: routeOutput.nodeAccessibilityValuesByID,
      connectTargetsByNodeID: routeOutput.connectTargetsByNodeID,
      nodeValidationIssueMessagesByID: [:],
      portVisibility: routeOutput.portVisibility,
      portMarkerLayout: routeOutput.portMarkerLayout,
      routeSignature: routeOutput.signature,
      contentSize: routeOutput.contentSize,
      resolvedCanvasColorScheme: nil,
      showSimulationOverlay: false,
      openEditor: { _ in },
      requestKeyboardFocus: requestKeyboardFocus
    )
  }
}
