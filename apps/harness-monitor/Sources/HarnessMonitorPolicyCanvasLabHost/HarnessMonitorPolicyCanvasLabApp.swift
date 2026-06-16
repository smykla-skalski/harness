import AppKit
import HarnessMonitorPolicyCanvas
import SwiftUI

private enum PolicyCanvasLabWindowMetrics {
  static let autosaveName = "PolicyCanvasLabWindowFrame"
  static let defaultSize = CGSize(width: 1_440, height: 900)
  static let minimumSize = CGSize(width: 960, height: 620)
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
          PolicyCanvasLabWindowFrameAutosaveInstaller(
            autosaveName: PolicyCanvasLabWindowMetrics.autosaveName
          )
        }
    }
    .defaultSize(
      width: PolicyCanvasLabWindowMetrics.defaultSize.width,
      height: PolicyCanvasLabWindowMetrics.defaultSize.height
    )
    .windowResizability(.contentMinSize)
    .restorationBehavior(.automatic)
  }
}

private struct PolicyCanvasLabWindowFrameAutosaveInstaller: NSViewRepresentable {
  let autosaveName: String

  func makeNSView(context _: Context) -> PolicyCanvasLabWindowFrameAutosaveView {
    PolicyCanvasLabWindowFrameAutosaveView(autosaveName: autosaveName)
  }

  func updateNSView(_ nsView: PolicyCanvasLabWindowFrameAutosaveView, context _: Context) {
    nsView.autosaveName = autosaveName
    nsView.applyAutosaveNameIfNeeded()
  }
}

private final class PolicyCanvasLabWindowFrameAutosaveView: NSView {
  var autosaveName: String {
    didSet {
      applyAutosaveNameIfNeeded()
    }
  }

  private weak var configuredWindow: NSWindow?
  private var configuredAutosaveName: String?

  init(autosaveName: String) {
    self.autosaveName = autosaveName
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyAutosaveNameIfNeeded()
  }

  func applyAutosaveNameIfNeeded() {
    guard let window else { return }
    guard configuredWindow !== window || configuredAutosaveName != autosaveName else { return }
    window.setFrameAutosaveName(autosaveName)
    configuredWindow = window
    configuredAutosaveName = autosaveName
  }
}
