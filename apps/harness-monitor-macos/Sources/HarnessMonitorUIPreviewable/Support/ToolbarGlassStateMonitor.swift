import AppKit
import SwiftUI

// NSWindow draws a titlebar/toolbar separator at the AppKit level, above all
// SwiftUI content. On macOS 26 with Liquid Glass the NavigationSplitView
// sidebar is translucent glass, so that line bleeds through the sidebar area
// even though ToolbarBaselineOverlay only draws in the detail column (starting
// at the sidebar's right edge). Setting titlebarSeparatorStyle to .none makes
// the custom overlay the sole separator, correctly scoped to the detail column.
// NSToolbar.showsBaselineSeparator was deprecated in macOS 15 - titlebarSeparatorStyle
// is the replacement (available since macOS 12).
//
// The NSView subclass uses viewDidMoveToWindow() instead of DispatchQueue.main.async
// because makeNSView is called before SwiftUI inserts the view into the window
// hierarchy. The async dispatch fires while window is still nil and the call
// silently no-ops. viewDidMoveToWindow() is the guaranteed AppKit callback that
// fires with a non-nil window. Titlebar transparency is opt-in because only the
// tabbed dashboard/session windows should sample through to their blur hosts.
private final class _TitlebarSeparatorSuppressorView: NSView {
  var titlebarAppearsTransparent = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyWindowOverrides()
  }

  func applyWindowOverrides() {
    window?.titlebarSeparatorStyle = .none
    window?.titlebarAppearsTransparent = titlebarAppearsTransparent
    if titlebarAppearsTransparent {
      window?.styleMask.insert(.fullSizeContentView)
    }
  }
}

private final class _NativeToolbarScrollEdgeAccessoryView: NSView {
  var accessoryHeight: CGFloat {
    didSet {
      if oldValue != accessoryHeight {
        invalidateIntrinsicContentSize()
        frame.size.height = accessoryHeight
      }
    }
  }

  init(height: CGFloat) {
    accessoryHeight = height
    super.init(frame: NSRect(x: 0, y: 0, width: 0, height: height))
    translatesAutoresizingMaskIntoConstraints = false
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentHuggingPriority(.required, for: .vertical)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .vertical)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: accessoryHeight)
  }

  override var isFlipped: Bool {
    true
  }
}

private final class _NativeToolbarScrollEdgeBackdropInstallerView: NSView {
  var accessoryHeight: CGFloat
  private let accessoryView: _NativeToolbarScrollEdgeAccessoryView
  private var accessoryController: NSTitlebarAccessoryViewController?
  private weak var installedWindow: NSWindow?

  init(accessoryHeight: CGFloat) {
    self.accessoryHeight = accessoryHeight
    accessoryView = _NativeToolbarScrollEdgeAccessoryView(height: accessoryHeight)
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyWindowAccessory()
  }

  func update(accessoryHeight: CGFloat) {
    self.accessoryHeight = accessoryHeight
    accessoryView.accessoryHeight = accessoryHeight
    accessoryController?.fullScreenMinHeight = accessoryHeight
    applyWindowAccessory()
  }

  func uninstallAccessory() {
    if let accessoryController, let installedWindow {
      if let index = installedWindow.titlebarAccessoryViewControllers.firstIndex(where: {
        $0 === accessoryController
      }) {
        installedWindow.removeTitlebarAccessoryViewController(at: index)
      }
    }
    accessoryController = nil
    installedWindow = nil
  }

  private func applyWindowAccessory() {
    guard let window else {
      uninstallAccessory()
      return
    }
    window.titlebarSeparatorStyle = .none
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)

    if installedWindow !== window {
      uninstallAccessory()
      installedWindow = window
      let controller = NSTitlebarAccessoryViewController()
      controller.layoutAttribute = .bottom
      controller.view = accessoryView
      controller.fullScreenMinHeight = accessoryHeight
      if #available(macOS 26.1, *) {
        controller.preferredScrollEdgeEffectStyle = .soft
      }
      accessoryController = controller
      window.addTitlebarAccessoryViewController(controller)
    } else if #available(macOS 26.1, *) {
      accessoryController?.preferredScrollEdgeEffectStyle = .soft
    }
  }
}

private struct NativeToolbarScrollEdgeBackdropInstaller: NSViewRepresentable {
  static let defaultHeight: CGFloat = 64
  let accessoryHeight: CGFloat

  func makeNSView(context: Context) -> _NativeToolbarScrollEdgeBackdropInstallerView {
    _NativeToolbarScrollEdgeBackdropInstallerView(accessoryHeight: accessoryHeight)
  }

  func updateNSView(
    _ nsView: _NativeToolbarScrollEdgeBackdropInstallerView,
    context: Context
  ) {
    nsView.update(accessoryHeight: accessoryHeight)
  }

  static func dismantleNSView(
    _ nsView: _NativeToolbarScrollEdgeBackdropInstallerView,
    coordinator: ()
  ) {
    nsView.uninstallAccessory()
  }
}

private struct NativeToolbarScrollEdgeBackdropModifier: ViewModifier {
  let toolbarBackgroundVisibility: Visibility?

  private var isEnabled: Bool {
    if case .hidden? = toolbarBackgroundVisibility {
      return true
    }
    return false
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.background(
        NativeToolbarScrollEdgeBackdropInstaller(
          accessoryHeight: NativeToolbarScrollEdgeBackdropInstaller.defaultHeight
        )
      )
    } else {
      content
    }
  }
}

private struct ToolbarBaselineSeparatorSuppressor: NSViewRepresentable {
  let titlebarAppearsTransparent: Bool

  func makeNSView(context: Context) -> _TitlebarSeparatorSuppressorView {
    let view = _TitlebarSeparatorSuppressorView()
    view.titlebarAppearsTransparent = titlebarAppearsTransparent
    return view
  }

  func updateNSView(_ nsView: _TitlebarSeparatorSuppressorView, context: Context) {
    nsView.titlebarAppearsTransparent = titlebarAppearsTransparent
    nsView.applyWindowOverrides()
  }
}

extension View {
  public func nativeToolbarScrollEdgeBackdrop(
    toolbarBackgroundVisibility: Visibility?
  ) -> some View {
    modifier(
      NativeToolbarScrollEdgeBackdropModifier(
        toolbarBackgroundVisibility: toolbarBackgroundVisibility
      )
    )
  }

  public func suppressToolbarBaselineSeparator(
    titlebarAppearsTransparent: Bool = false
  ) -> some View {
    background(
      ToolbarBaselineSeparatorSuppressor(
        titlebarAppearsTransparent: titlebarAppearsTransparent
      )
    )
  }

  public func suppressToolbarBaselineSeparator(
    markedAs identifier: String,
    titlebarAppearsTransparent: Bool = false
  ) -> some View {
    suppressToolbarBaselineSeparator(titlebarAppearsTransparent: titlebarAppearsTransparent)
      .overlay {
        AccessibilityTextMarker(identifier: identifier, text: "suppressed")
      }
  }
}

struct OptionalToolbarBaselineOverlayModifier: ViewModifier {
  let isEnabled: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.toolbarBaselineOverlay()
    } else {
      content
    }
  }
}
