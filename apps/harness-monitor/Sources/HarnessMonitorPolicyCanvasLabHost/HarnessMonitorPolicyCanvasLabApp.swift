import AppKit
import HarnessMonitorPolicyCanvas
import SwiftUI

private enum PolicyCanvasLabWindowMetrics {
  static let frameDefaultsKey = "PolicyCanvasLabWindowFrame"
  static let defaultSize = CGSize(width: 1_440, height: 900)
  static let minimumSize = CGSize(width: 960, height: 620)

  static var launchSize: CGSize {
    PolicyCanvasLabWindowFrameStore.savedSize(
      forKey: frameDefaultsKey,
      defaultSize: defaultSize,
      minimumSize: minimumSize
    )
  }
}

@main
struct HarnessMonitorPolicyCanvasLabApp: App {
  var body: some Scene {
    WindowGroup("Policy Canvas Lab") {
      PolicyCanvasLabWindowView()
        .writingToolsBehavior(.disabled)
        .frame(
          minWidth: PolicyCanvasLabWindowMetrics.minimumSize.width,
          minHeight: PolicyCanvasLabWindowMetrics.minimumSize.height
        )
        .background {
          PolicyCanvasLabWindowFramePersistenceInstaller(
            defaultsKey: PolicyCanvasLabWindowMetrics.frameDefaultsKey,
            minimumSize: PolicyCanvasLabWindowMetrics.minimumSize
          )
        }
    }
    .defaultSize(
      width: PolicyCanvasLabWindowMetrics.launchSize.width,
      height: PolicyCanvasLabWindowMetrics.launchSize.height
    )
    .windowResizability(.contentMinSize)
    .restorationBehavior(.disabled)
  }
}

private enum PolicyCanvasLabWindowFrameStore {
  static func savedSize(
    forKey key: String,
    defaultSize: CGSize,
    minimumSize: CGSize
  ) -> CGSize {
    guard let frame = savedFrame(forKey: key) else { return defaultSize }
    return CGSize(
      width: max(frame.width, minimumSize.width),
      height: max(frame.height, minimumSize.height)
    )
  }

  @MainActor
  static func restoreFrame(
    on window: NSWindow,
    forKey key: String,
    minimumSize: CGSize
  ) {
    guard let frame = savedFrame(forKey: key) else { return }
    window.setFrame(
      visibleFrame(for: frame, minimumSize: minimumSize),
      display: true
    )
  }

  static func persistFrame(_ frame: NSRect, forKey key: String) {
    guard frame.width.isFinite, frame.height.isFinite else { return }
    UserDefaults.standard.set(NSStringFromRect(frame), forKey: key)
  }

  private static func savedFrame(forKey key: String) -> NSRect? {
    guard
      let rawFrame = UserDefaults.standard.string(forKey: key),
      !rawFrame.isEmpty
    else {
      return nil
    }

    let frame = NSRectFromString(rawFrame)
    guard
      frame.origin.x.isFinite,
      frame.origin.y.isFinite,
      frame.width.isFinite,
      frame.height.isFinite,
      frame.width > .zero,
      frame.height > .zero
    else {
      return nil
    }
    return frame
  }

  private static func visibleFrame(for frame: NSRect, minimumSize: CGSize) -> NSRect {
    guard let screenFrame = screenFrame(containing: frame) else { return frame }
    let width = min(max(frame.width, minimumSize.width), screenFrame.width)
    let height = min(max(frame.height, minimumSize.height), screenFrame.height)
    let originX = min(max(frame.minX, screenFrame.minX), screenFrame.maxX - width)
    let originY = min(max(frame.minY, screenFrame.minY), screenFrame.maxY - height)
    return NSRect(x: originX, y: originY, width: width, height: height)
  }

  private static func screenFrame(containing frame: NSRect) -> NSRect? {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
      return screen.visibleFrame
    }
    return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
  }
}

private struct PolicyCanvasLabWindowFramePersistenceInstaller: NSViewRepresentable {
  let defaultsKey: String
  let minimumSize: CGSize

  func makeNSView(context _: Context) -> PolicyCanvasLabWindowFramePersistenceView {
    PolicyCanvasLabWindowFramePersistenceView(defaultsKey: defaultsKey, minimumSize: minimumSize)
  }

  func updateNSView(_ nsView: PolicyCanvasLabWindowFramePersistenceView, context _: Context) {
    nsView.defaultsKey = defaultsKey
    nsView.minimumSize = minimumSize
    nsView.configureWindowIfNeeded()
  }
}

private final class PolicyCanvasLabWindowFramePersistenceView: NSView {
  var defaultsKey: String {
    didSet {
      configureWindowIfNeeded()
    }
  }

  var minimumSize: CGSize {
    didSet {
      configureWindowIfNeeded()
    }
  }

  private weak var configuredWindow: NSWindow?
  private var configuredDefaultsKey: String?
  private var isApplyingStoredFrame = false
  private var observerTokens: [NSObjectProtocol] = []

  init(defaultsKey: String, minimumSize: CGSize) {
    self.defaultsKey = defaultsKey
    self.minimumSize = minimumSize
    super.init(frame: .zero)
  }

  deinit {
    MainActor.assumeIsolated {
      removeObservers()
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureWindowIfNeeded()
  }

  func configureWindowIfNeeded() {
    guard let window else { return }
    guard configuredWindow !== window || configuredDefaultsKey != defaultsKey else { return }
    removeObservers()
    isApplyingStoredFrame = true
    PolicyCanvasLabWindowFrameStore.restoreFrame(
      on: window,
      forKey: defaultsKey,
      minimumSize: minimumSize
    )
    isApplyingStoredFrame = false
    configuredWindow = window
    configuredDefaultsKey = defaultsKey
    installObservers(for: window)
  }

  private func installObservers(for window: NSWindow) {
    let center = NotificationCenter.default
    observerTokens = [
      center.addObserver(
        forName: NSWindow.didEndLiveResizeNotification,
        object: window,
        queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.persistCurrentWindowFrame()
        }
      },
      center.addObserver(
        forName: NSWindow.didResizeNotification,
        object: window,
        queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.configuredWindow?.inLiveResize == false else { return }
          self.persistCurrentWindowFrame()
        }
      },
      center.addObserver(
        forName: NSWindow.didMoveNotification,
        object: window,
        queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.persistCurrentWindowFrame()
        }
      },
      center.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.persistCurrentWindowFrame()
        }
      },
    ]
  }

  private func removeObservers() {
    let center = NotificationCenter.default
    observerTokens.forEach { center.removeObserver($0) }
    observerTokens.removeAll()
  }

  private func persistCurrentWindowFrame() {
    guard !isApplyingStoredFrame, let window = configuredWindow else { return }
    PolicyCanvasLabWindowFrameStore.persistFrame(window.frame, forKey: defaultsKey)
  }
}
