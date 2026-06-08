import AppKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Pointer tracking for the lab quality overlay, driven from AppKit rather than
/// SwiftUI. In this hosted `NSHostingView` canvas, `onContinuousHover`/`.help` on
/// a content-space overlay do not fire reliably, but the document view's mouse
/// events do (the same path that drives node dragging). So hover detection lives
/// here: a tracking area reports the pointer, the marks under it are published to
/// `viewModel.hoveredQualityMarks`, and the SwiftUI hover layer renders the
/// highlight and tooltip from that observed state.
///
/// Cost off the lab path (`qualityInspectionReport == nil`, the shipping default)
/// is one optional read plus an early return per move - no allocation, no
/// observation write. On the lab path the mark cache is rebuilt only when the
/// report generation changes, so each move filters a prebuilt array.
extension PolicyCanvasNativeDocumentView {
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
        owner: self
      )
    )
  }

  override func mouseMoved(with event: NSEvent) {
    refreshQualityHover(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with _: NSEvent) {
    clearQualityHover()
  }

  /// Publish the marks under `workspacePoint` (converted to content space with the
  /// same transform node hit-testing uses) when the set changes. The id-array
  /// guard keeps a still pointer from rewriting the observed state every frame.
  private func refreshQualityHover(at workspacePoint: CGPoint) {
    let viewModel = hostedState.snapshot.viewModel
    guard let report = viewModel.qualityInspectionReport else {
      clearQualityHover()
      return
    }
    if qualityHoverCacheGeneration != viewModel.qualityReportGeneration {
      qualityHoverCache = policyCanvasQualityHoverMarks(report: report)
      qualityHoverCacheGeneration = viewModel.qualityReportGeneration
    }
    let point = contentPoint(fromWorkspacePoint: workspacePoint)
    let active = policyCanvasQualityHoverMarks(in: qualityHoverCache, under: point)
    let ids = active.map(\.id)
    guard ids != qualityHoverActiveIDs else {
      return
    }
    qualityHoverActiveIDs = ids
    viewModel.hoveredQualityMarks = active
  }

  private func clearQualityHover() {
    guard !qualityHoverActiveIDs.isEmpty else {
      return
    }
    qualityHoverActiveIDs = []
    hostedState.snapshot.viewModel.hoveredQualityMarks = []
  }
}
