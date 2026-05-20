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
    context.coordinator.request = request
    view.applyRestoreWhenReady()
  }

  final class Coordinator {
    var request: SettingsScrollRestoreRequest?
    private var appliedRequest: SettingsScrollRestoreRequest?

    @MainActor
    func applyRestore(from view: NSView) {
      guard let request,
        appliedRequest != request
      else {
        return
      }
      guard let scrollView = SettingsScrollRestoreApplicator.findNearestScrollView(from: view)
      else {
        return
      }

      let maxOffset = SettingsScrollRestoreApplicator.maxOffset(in: scrollView)
      let targetOffset = SettingsScrollPersistencePolicy.restorationTargetOffset(
        storedOffset: request.offset,
        maxOffset: maxOffset
      )
      guard targetOffset > 0 else {
        return
      }

      SettingsScrollRestoreApplicator.setOffset(targetOffset, in: scrollView)
      appliedRequest = request
    }
  }

  private static func findNearestScrollView(from view: NSView) -> NSScrollView? {
    if let enclosingScrollView = view.enclosingScrollView {
      return enclosingScrollView
    }

    guard let window = view.window,
      let contentView = window.contentView
    else {
      return nil
    }

    let viewFrame = view.convert(view.bounds, to: nil)
    let scrollViews = contentView.settingsDescendantScrollViews().filter { scrollView in
      scrollView.window === window
        && !scrollView.isHidden
        && !scrollView.frame.isEmpty
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
}

final class SettingsScrollRestoreApplicatorView: NSView {
  weak var coordinator: SettingsScrollRestoreApplicator.Coordinator?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyRestoreWhenReady()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    applyRestoreWhenReady()
  }

  func applyRestoreWhenReady() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      coordinator?.applyRestore(from: self)
    }
  }
}

extension NSView {
  fileprivate func settingsDescendantScrollViews() -> [NSScrollView] {
    var result: [NSScrollView] = []
    if let scrollView = self as? NSScrollView {
      result.append(scrollView)
    }
    for subview in subviews {
      result.append(contentsOf: subview.settingsDescendantScrollViews())
    }
    return result
  }
}
