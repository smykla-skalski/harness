import AppKit
import SwiftUI

struct SettingsScrollRestoreApplicator: NSViewRepresentable {
  var request: SettingsScrollRestoreRequest?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> SettingsScrollRestoreApplicatorView {
    let view = SettingsScrollRestoreApplicatorView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ view: SettingsScrollRestoreApplicatorView, context: Context) {
    if context.coordinator.updateRequest(request) {
      view.applyRestoreWhenReady()
    }
  }

  final class Coordinator {
    var request: SettingsScrollRestoreRequest?
    private var appliedRequest: SettingsScrollRestoreRequest?
    private weak var cachedScrollView: NSScrollView?

    func updateRequest(_ request: SettingsScrollRestoreRequest?) -> Bool {
      guard self.request != request else {
        return false
      }
      self.request = request
      return request != nil
    }

    @MainActor
    func applyRestore(from view: NSView) {
      guard let request,
        appliedRequest != request
      else {
        return
      }

      let storedOffset = SettingsRestorationDefaults.normalizedScrollOffset(request.offset)
      guard storedOffset > 0 else {
        appliedRequest = request
        return
      }

      guard let scrollView = resolvedScrollView(from: view)
      else {
        return
      }

      let maxOffset = SettingsScrollRestoreApplicator.maxOffset(in: scrollView)
      let targetOffset = SettingsScrollPersistencePolicy.restorationTargetOffset(
        storedOffset: storedOffset,
        maxOffset: maxOffset
      )
      guard targetOffset > 0 else {
        appliedRequest = request
        return
      }

      SettingsScrollRestoreApplicator.setOffset(targetOffset, in: scrollView)
      appliedRequest = request
    }

    @MainActor
    private func resolvedScrollView(from view: NSView) -> NSScrollView? {
      if let cachedScrollView,
        SettingsScrollRestoreApplicator.isRestorationCandidate(cachedScrollView, for: view)
      {
        return cachedScrollView
      }

      guard let scrollView = SettingsScrollRestoreApplicator.findNearestScrollView(from: view)
      else {
        return nil
      }
      cachedScrollView = scrollView
      return scrollView
    }
  }

  private static func findNearestScrollView(from view: NSView) -> NSScrollView? {
    if let enclosingScrollView = view.enclosingScrollView,
      isRestorationCandidate(enclosingScrollView, for: view)
    {
      return enclosingScrollView
    }

    guard let window = view.window,
      let contentView = window.contentView
    else {
      return nil
    }

    let viewFrame = view.convert(view.bounds, to: nil)
    let scrollViews = descendantScrollViews(in: contentView).filter { scrollView in
      isRestorationCandidate(scrollView, in: window)
    }
    let containingMidpoint = scrollViews.filter { scrollView in
      scrollView.convert(scrollView.bounds, to: nil).contains(
        NSPoint(x: viewFrame.midX, y: viewFrame.midY)
      )
    }

    if let scrollView = largestScrollView(containingMidpoint) {
      return scrollView
    }

    return scrollViews.max { left, right in
      intersectionArea(left, with: viewFrame) < intersectionArea(right, with: viewFrame)
    }
  }

  private static func isRestorationCandidate(_ scrollView: NSScrollView, for view: NSView)
    -> Bool
  {
    guard let window = view.window else {
      return false
    }
    return isRestorationCandidate(scrollView, in: window)
  }

  private static func isRestorationCandidate(_ scrollView: NSScrollView, in window: NSWindow)
    -> Bool
  {
    scrollView.window === window
      && !scrollView.isHidden
      && !scrollView.frame.isEmpty
      && scrollView.documentView != nil
  }

  private static func currentOffset(in scrollView: NSScrollView) -> CGFloat {
    let visibleY = scrollView.documentVisibleRect.origin.y
    let offset: CGFloat
    if scrollView.documentView?.isFlipped == false {
      offset = maxOffset(in: scrollView) - visibleY
    } else {
      offset = visibleY
    }
    return SettingsRestorationDefaults.normalizedScrollOffset(offset)
  }

  private static func maxOffset(in scrollView: NSScrollView) -> CGFloat {
    guard let documentView = scrollView.documentView else {
      return 0
    }
    return max(0, documentView.frame.height - scrollView.contentView.bounds.height)
  }

  private static func setOffset(_ offset: CGFloat, in scrollView: NSScrollView) {
    guard abs(currentOffset(in: scrollView) - offset) > 1 else {
      return
    }

    let documentY: CGFloat
    if scrollView.documentView?.isFlipped == false {
      documentY = maxOffset(in: scrollView) - offset
    } else {
      documentY = offset
    }
    let contentView = scrollView.contentView
    contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: documentY))
    scrollView.reflectScrolledClipView(contentView)
  }

  private static func largestScrollView(_ scrollViews: [NSScrollView]) -> NSScrollView? {
    scrollViews.max { left, right in
      area(left.convert(left.bounds, to: nil)) < area(right.convert(right.bounds, to: nil))
    }
  }

  private static func area(_ rect: NSRect) -> CGFloat {
    guard !rect.isEmpty else {
      return 0
    }
    return rect.width * rect.height
  }

  private static func intersectionArea(_ scrollView: NSScrollView, with frame: NSRect) -> CGFloat {
    let intersection = scrollView.convert(scrollView.bounds, to: nil).intersection(frame)
    return area(intersection)
  }

  private static func descendantScrollViews(in root: NSView) -> [NSScrollView] {
    var result: [NSScrollView] = []
    var stack = [root]
    while let view = stack.popLast() {
      if let scrollView = view as? NSScrollView {
        result.append(scrollView)
      }
      stack.append(contentsOf: view.subviews)
    }
    return result
  }
}

final class SettingsScrollRestoreApplicatorView: NSView {
  weak var coordinator: SettingsScrollRestoreApplicator.Coordinator?
  private var isApplyScheduled = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyRestoreWhenReady()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    applyRestoreWhenReady()
  }

  func applyRestoreWhenReady() {
    guard !isApplyScheduled else { return }
    isApplyScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      isApplyScheduled = false
      coordinator?.applyRestore(from: self)
    }
  }
}
