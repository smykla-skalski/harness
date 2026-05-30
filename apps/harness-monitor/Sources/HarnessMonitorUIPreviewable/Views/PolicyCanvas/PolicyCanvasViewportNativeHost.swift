import AppKit
import HarnessMonitorKit
import SwiftUI

struct PolicyCanvasViewportNativeHost: NSViewRepresentable {
  var snapshot: PolicyCanvasViewportHostedSnapshot
  var zoom: CGFloat
  var isActive = true
  var isEmpty = false
  var request: PolicyCanvasViewportScrollRequest?
  var onFulfillRequest: @MainActor (PolicyCanvasViewportScrollRequest, Bool) -> Void
  var onZoomChange: @MainActor (CGFloat) -> Void
  var onViewportChange: @MainActor (PolicyCanvasViewportObservedState) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(snapshot: snapshot)
  }

  func makeNSView(context: Context) -> PolicyCanvasNativeScrollView {
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.magnificationDidChange = { [weak coordinator = context.coordinator] zoom in
      coordinator?.handleViewportZoomChange(zoom)
    }
    scrollView.viewportDidChange = { [weak coordinator = context.coordinator] observedState in
      coordinator?.handleViewportChange(observedState)
    }
    scrollView.ensureDocumentRoot(
      state: context.coordinator.hostedState,
      size: snapshot.contentSize
    )
    return scrollView
  }

  func updateNSView(_ scrollView: PolicyCanvasNativeScrollView, context: Context) {
    context.coordinator.onFulfillRequest = onFulfillRequest
    context.coordinator.onZoomChange = onZoomChange
    context.coordinator.onViewportChange = onViewportChange
    context.coordinator.hostedState.update(snapshot: snapshot)
    scrollView.magnificationDidChange = { [weak coordinator = context.coordinator] zoom in
      coordinator?.handleViewportZoomChange(zoom)
    }
    scrollView.viewportDidChange = { [weak coordinator = context.coordinator] observedState in
      coordinator?.handleViewportChange(observedState)
    }
    scrollView.setInteractionEnabled(isActive && !isEmpty)
    scrollView.ensureDocumentRoot(
      state: context.coordinator.hostedState,
      size: snapshot.contentSize
    )
    context.coordinator.applyModelZoomIfNeeded(zoom, to: scrollView)
    context.coordinator.updateRequest(request)
    context.coordinator.applyPendingRequest(on: scrollView)
  }

  @MainActor
  final class Coordinator {
    let hostedState: PolicyCanvasViewportHostedState
    var onFulfillRequest: ((PolicyCanvasViewportScrollRequest, Bool) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?
    var onViewportChange: ((PolicyCanvasViewportObservedState) -> Void)?
    private var request: PolicyCanvasViewportScrollRequest?
    private var appliedRequest: PolicyCanvasViewportScrollRequest?
    private var isApplyingModelZoom = false
    private var isRetryScheduled = false
    private var pendingObservedState: PolicyCanvasViewportObservedState?
    private var hasScheduledViewportFlush = false

    init(snapshot: PolicyCanvasViewportHostedSnapshot) {
      hostedState = PolicyCanvasViewportHostedState(snapshot: snapshot)
    }

    func updateRequest(_ request: PolicyCanvasViewportScrollRequest?) {
      guard self.request != request else {
        return
      }
      self.request = request
    }

    func handleViewportZoomChange(_ zoom: CGFloat) {
      guard !isApplyingModelZoom else {
        return
      }
      onZoomChange?(zoom)
    }

    func handleViewportChange(_ observedState: PolicyCanvasViewportObservedState) {
      guard onViewportChange != nil else {
        return
      }
      // Coalesce. `reportViewportStateIfNeeded` fires from several AppKit
      // callbacks per scroll frame (scrollWheel + reflectScrolledClipView),
      // and the hop off the AppKit layout pass is still required so the
      // observable write does not land mid-scroll-layout. Keep only the latest
      // state and drain it with a single scheduled hop instead of spawning a
      // Task per call, so a fast scroll cannot pile up redundant flushes.
      pendingObservedState = observedState
      guard !hasScheduledViewportFlush else {
        return
      }
      hasScheduledViewportFlush = true
      Task { @MainActor in
        self.hasScheduledViewportFlush = false
        guard let pending = self.pendingObservedState else {
          return
        }
        self.pendingObservedState = nil
        self.onViewportChange?(pending)
      }
    }

    func applyModelZoomIfNeeded(
      _ zoom: CGFloat,
      to scrollView: PolicyCanvasNativeScrollView
    ) {
      guard abs(scrollView.magnification - zoom) > 0.001 else {
        return
      }
      isApplyingModelZoom = true
      scrollView.setMagnification(zoom, centeredAt: scrollView.visibleDocumentCenter)
      isApplyingModelZoom = false
    }

    func applyPendingRequest(on scrollView: PolicyCanvasNativeScrollView) {
      guard let request, appliedRequest != request else {
        return
      }
      switch scrollView.applyScrollRequest(request.point) {
      case .applied(let didScroll):
        onFulfillRequest?(request, didScroll)
        appliedRequest = request
        isRetryScheduled = false
      case .needsRetry:
        scheduleRetry(on: scrollView, request: request)
      }
    }

    private func scheduleRetry(
      on scrollView: PolicyCanvasNativeScrollView,
      request: PolicyCanvasViewportScrollRequest
    ) {
      guard !isRetryScheduled else {
        return
      }
      isRetryScheduled = true
      DispatchQueue.main.async { [weak self, weak scrollView] in
        guard let self else {
          return
        }
        self.isRetryScheduled = false
        guard let scrollView, self.request == request else {
          return
        }
        self.applyPendingRequest(on: scrollView)
      }
    }
  }
}
