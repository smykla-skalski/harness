import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasCommandScrollTests {
  @Test("native scroll view recenters after the viewport becomes available")
  func nativeScrollViewRecentersAfterLateLayout() {
    let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let rootView = NSView(frame: frame)
    let scrollView = PolicyCanvasNativeScrollView()

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

    window.contentView = rootView
    window.layoutIfNeeded()
    rootView.layoutSubtreeIfNeeded()

    let requestPoint = CGPoint(x: 900, y: 700)
    let initialResult = scrollView.applyScrollRequest(requestPoint)
    #expect(initialResult == .needsRetry)
    #expect(scrollView.contentView.bounds.origin == .zero)
    #expect(scrollView.usesPredominantAxisScrolling == false)

    scrollView.frame = frame
    rootView.addSubview(scrollView)
    scrollView.setTestingDocumentContent(
      Color.clear.frame(width: 2_000, height: 1_600),
      size: CGSize(width: 2_000, height: 1_600)
    )
    window.layoutIfNeeded()
    rootView.layoutSubtreeIfNeeded()
    let finalResult = scrollView.applyScrollRequest(requestPoint)

    #expect(finalResult == .applied(true))
    #expect(scrollView.usesPredominantAxisScrolling == false)
    #expect(abs(scrollView.contentView.bounds.origin.x - requestPoint.x) < 1.5)
    #expect(abs(scrollView.contentView.bounds.origin.y - requestPoint.y) < 1.5)
  }

  @MainActor
  @Test("native scroll view centers a smaller document while keeping free diagonal scrolling")
  func nativeScrollViewCentersSmallerDocument() {
    let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.frame = frame
    scrollView.setTestingDocumentContent(
      Color.clear.frame(width: 320, height: 240),
      size: CGSize(width: 320, height: 240)
    )

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
    window.layoutIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    #expect(scrollView.usesPredominantAxisScrolling == false)
    #expect(abs(scrollView.contentView.bounds.origin.x + 160) < 1.5)
    #expect(abs(scrollView.contentView.bounds.origin.y + 120) < 1.5)
  }

  @MainActor
  @Test("native scroll view preserves the visible center when the viewport size changes")
  func nativeScrollViewPreservesTheVisibleCenterWhenTheViewportSizeChanges() {
    let initialFrame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let resizedFrame = CGRect(x: 0, y: 0, width: 860, height: 620)
    let rootView = NSView(frame: initialFrame)
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.frame = initialFrame
    scrollView.autoresizingMask = [.width, .height]
    scrollView.setTestingDocumentContent(
      Color.clear.frame(width: 2_400, height: 1_800),
      size: CGSize(width: 2_400, height: 1_800)
    )
    rootView.addSubview(scrollView)

    let window = NSWindow(
      contentRect: initialFrame,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    window.contentView = rootView
    window.layoutIfNeeded()
    rootView.layoutSubtreeIfNeeded()

    let initialResult = scrollView.applyScrollRequest(CGPoint(x: 900, y: 700))
    #expect(initialResult == .applied(true))
    let initialCenter = scrollView.visibleDocumentCenter

    window.setContentSize(resizedFrame.size)
    window.layoutIfNeeded()
    rootView.layoutSubtreeIfNeeded()

    let resizedCenter = scrollView.visibleDocumentCenter
    #expect(abs(resizedCenter.x - initialCenter.x) < 1.5)
    #expect(abs(resizedCenter.y - initialCenter.y) < 1.5)
  }

  @MainActor
  @Test("native scroll view rebinds the hosted root when a reused host gets a new state")
  func nativeScrollViewRebindsHostedRootState() throws {
    let focusedComponent = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let state1 = PolicyCanvasViewportHostedState(
      snapshot: hostedSnapshot(focusedComponent: focusedComponent)
    )
    let state2 = PolicyCanvasViewportHostedState(
      snapshot: hostedSnapshot(focusedComponent: focusedComponent)
    )
    let scrollView = PolicyCanvasNativeScrollView()

    scrollView.ensureDocumentRoot(state: state1, size: state1.snapshot.contentSize)
    let documentView = try #require(scrollView.documentView as? PolicyCanvasNativeDocumentView)
    #expect(documentView.hostedState === state1)
    #expect(documentView.rootViewState === state1)

    scrollView.ensureDocumentRoot(state: state2, size: state2.snapshot.contentSize)

    #expect(documentView.hostedState === state2)
    #expect(documentView.rootViewState === state2)
  }

  @MainActor
  @Test("native scroll view expands the hosted workspace near the trailing edge")
  func nativeScrollViewExpandsHostedWorkspaceNearTrailingEdge() throws {
    let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let focusedComponent = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let state = PolicyCanvasViewportHostedState(
      snapshot: hostedSnapshot(focusedComponent: focusedComponent)
    )
    let scrollView = PolicyCanvasNativeScrollView()
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
    scrollView.ensureDocumentRoot(state: state, size: state.snapshot.contentSize)
    window.layoutIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let documentView = try #require(scrollView.documentView)
    let initialWidth = documentView.frame.width

    scrollView.contentView.scroll(
      to: CGPoint(
        x: initialWidth - frame.width - 100,
        y: 0
      )
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)

    #expect(documentView.frame.width > initialWidth)
  }

  @Test("interactive layers use layout positions instead of visual offsets")
  func interactiveLayersUseLayoutPositions() throws {
    let nodeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNodeLayer.swift"
    )
    let groupSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasGroupViews.swift"
    )
    let simulationSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasSimulationLayer.swift"
    )
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(!nodeSource.contains(".offset(x: node.position.x, y: node.position.y)"))
    #expect(
      nodeSource.contains("x: node.position.x + PolicyCanvasLayout.nodeSize.width / 2")
    )
    #expect(
      nodeSource.contains("y: node.position.y + PolicyCanvasLayout.nodeSize.height / 2")
    )
    #expect(!groupSource.contains(".offset(x: group.frame.minX, y: group.frame.minY)"))
    #expect(groupSource.contains(".position(x: group.frame.midX, y: group.frame.midY)"))
    #expect(!simulationSource.contains(".offset(x: node.position.x, y: node.position.y)"))
    #expect(
      coordinatorSource
        .components(separatedBy: ".policyCanvasDocumentLayer(size: snapshot.contentSize)")
        .count >= 7
    )
    #expect(
      coordinatorSource
        .contains("frame(width: size.width, height: size.height, alignment: .topLeading)")
    )
  }
}
