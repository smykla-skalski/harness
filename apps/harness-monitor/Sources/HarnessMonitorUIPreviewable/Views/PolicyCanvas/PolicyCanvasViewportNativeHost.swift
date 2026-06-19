import AppKit
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasViewportNativeHost: NSViewRepresentable {
  var snapshot: PolicyCanvasViewportHostedSnapshot
  var zoom: CGFloat
  var resizeZoomBehavior: PolicyCanvasViewportResizeZoomBehavior
  var viewportIdentity: String?
  var observationStore = PolicyCanvasViewportObservationStore()
  var isActive = true
  var isEmpty = false
  var request: PolicyCanvasViewportScrollRequest?
  var onFulfillRequest: @MainActor (PolicyCanvasViewportScrollRequest, Bool) -> Void
  var onZoomChange: @MainActor (CGFloat) -> Void
  var onViewportChange: @MainActor (PolicyCanvasViewportObservedState, String?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      snapshot: snapshot,
      observationStore: observationStore,
      viewportIdentity: viewportIdentity
    )
  }

  func makeNSView(context: Context) -> PolicyCanvasNativeScrollView {
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.viewportResizeZoomBehavior = resizeZoomBehavior
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
    context.coordinator.currentViewportIdentity = viewportIdentity
    context.coordinator.hostedState.update(
      snapshot: snapshot,
      observationStore: observationStore,
      viewportIdentity: viewportIdentity
    )
    scrollView.viewportResizeZoomBehavior = resizeZoomBehavior
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

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView scrollView: PolicyCanvasNativeScrollView,
    context _: Context
  ) -> CGSize? {
    let width = proposal.width ?? scrollView.bounds.width
    let height = proposal.height ?? scrollView.bounds.height
    guard width.isFinite, height.isFinite, width > 0, height > 0 else {
      return nil
    }
    return CGSize(width: width, height: height)
  }

  @MainActor
  final class Coordinator {
    private static let zoomChangeDebounceDelayNanoseconds: UInt64 = 120_000_000
    private static let viewportChangeDebounceDelayNanoseconds: UInt64 = 120_000_000

    let hostedState: PolicyCanvasViewportHostedState
    var onFulfillRequest: ((PolicyCanvasViewportScrollRequest, Bool) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?
    var onViewportChange: ((PolicyCanvasViewportObservedState, String?) -> Void)?
    var currentViewportIdentity: String?
    private var request: PolicyCanvasViewportScrollRequest?
    private var appliedRequest: PolicyCanvasViewportScrollRequest?
    private var isApplyingModelZoom = false
    // AppKit renders live magnification immediately. Keep SwiftUI's model
    // writes behind that path so trackpad zoom does not rebuild canvas chrome
    // once per high-frequency magnify event.
    private var pendingZoom: CGFloat?
    private var zoomFlushTask: Task<Void, Never>?
    private var isRetryScheduled = false
    private var pendingObservedState: (identity: String?, state: PolicyCanvasViewportObservedState)?
    private var viewportFlushTask: Task<Void, Never>?

    init(
      snapshot: PolicyCanvasViewportHostedSnapshot,
      observationStore: PolicyCanvasViewportObservationStore =
        PolicyCanvasViewportObservationStore(),
      viewportIdentity: String?
    ) {
      hostedState = PolicyCanvasViewportHostedState(
        snapshot: snapshot,
        observationStore: observationStore,
        viewportIdentity: viewportIdentity
      )
      currentViewportIdentity = viewportIdentity
    }

    deinit {
      zoomFlushTask?.cancel()
      viewportFlushTask?.cancel()
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
      pendingZoom = zoom
      scheduleZoomFlushIfNeeded()
    }

    func handleViewportChange(_ observedState: PolicyCanvasViewportObservedState) {
      guard onViewportChange != nil else {
        return
      }
      // Debounce. `reportViewportStateIfNeeded` fires from several AppKit
      // callbacks per scroll frame. AppKit already moves and magnifies the
      // document live; publishing every observed rect back into SwiftUI wakes
      // the minimap/scene-storage path during the gesture and can trigger
      // full GraphHost transactions. Keep the latest state and publish the
      // trailing value after the interaction burst.
      pendingObservedState = (currentViewportIdentity, observedState)
      scheduleViewportFlush()
    }

    func applyModelZoomIfNeeded(
      _ zoom: CGFloat,
      to scrollView: PolicyCanvasNativeScrollView
    ) {
      guard !hasDeferredUserZoom else {
        return
      }
      guard abs(scrollView.magnification - zoom) > 0.001 else {
        return
      }
      isApplyingModelZoom = true
      scrollView.setMagnification(zoom, centeredAt: scrollView.visibleDocumentCenter)
      isApplyingModelZoom = false
    }

    private var hasDeferredUserZoom: Bool {
      pendingZoom != nil || zoomFlushTask != nil
    }

    private func scheduleZoomFlushIfNeeded() {
      zoomFlushTask?.cancel()
      zoomFlushTask = Task { @MainActor in
        try? await Task.sleep(
          nanoseconds: Self.zoomChangeDebounceDelayNanoseconds)
        guard !Task.isCancelled else {
          return
        }
        self.flushPendingZoomChange()
      }
    }

    private func flushPendingZoomChange() {
      zoomFlushTask = nil
      guard let zoom = pendingZoom else {
        return
      }
      pendingZoom = nil
      onZoomChange?(zoom)
    }

    private func scheduleViewportFlush() {
      viewportFlushTask?.cancel()
      viewportFlushTask = Task { @MainActor in
        try? await Task.sleep(
          nanoseconds: Self.viewportChangeDebounceDelayNanoseconds)
        guard !Task.isCancelled else {
          return
        }
        self.flushPendingViewportChange()
      }
    }

    private func flushPendingViewportChange() {
      viewportFlushTask = nil
      guard let pending = pendingObservedState else {
        return
      }
      pendingObservedState = nil
      onViewportChange?(pending.state, pending.identity)
    }

    func applyPendingRequest(on scrollView: PolicyCanvasNativeScrollView) {
      guard let request, appliedRequest != request else {
        return
      }
      switch scrollView.applyScrollRequest(request.target) {
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
