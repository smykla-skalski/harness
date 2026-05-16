import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import OSLog
import SwiftUI

struct SessionWindowTabbing: ViewModifier {
  enum Role: Equatable {
    case dashboard
    case session
  }

  let role: Role
  var tabTitle: String = ""
  var pendingDecisionCount: Int = 0
  var pendingDecisionSeverity: DecisionSeverity?
  @AppStorage(SessionWindowTabbingPreference.storageKey)
  private var preferenceRawValue = SessionWindowTabbingPreference.defaultValue.rawValue

  private var preference: SessionWindowTabbingPreference {
    SessionWindowTabbingPreference.resolved(rawValue: preferenceRawValue)
  }

  func body(content: Content) -> some View {
    content.background(
      SessionWindowTabbingAccessor(
        configuration: .init(
          role: role,
          preference: preference,
          tabTitle: tabTitle,
          pendingDecisionCount: pendingDecisionCount,
          pendingDecisionSeverity: pendingDecisionSeverity
        )
      )
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    )
  }
}

struct SessionWindowTabbingAccessor: NSViewRepresentable {
  struct Configuration: Equatable {
    let role: SessionWindowTabbing.Role
    let preference: SessionWindowTabbingPreference
    let tabTitle: String
    let pendingDecisionCount: Int
    let pendingDecisionSeverity: DecisionSeverity?
  }

  let configuration: Configuration

  func makeNSView(context: Context) -> SessionWindowTabbingAccessorView {
    let view = SessionWindowTabbingAccessorView()
    view.configuration = configuration
    return view
  }

  func updateNSView(_ nsView: SessionWindowTabbingAccessorView, context: Context) {
    nsView.configuration = configuration
    nsView.scheduleWindowTabbingApplication()
  }

  static func dismantleNSView(_ nsView: SessionWindowTabbingAccessorView, coordinator: ()) {
    nsView.cancelWindowTabbingUpdates()
  }
}

final class SessionWindowTabbingAccessorView: NSView {
  private static let log = Logger(
    subsystem: "io.harnessmonitor",
    category: "SessionWindowTabbing"
  )

  var configuration = SessionWindowTabbingAccessor.Configuration(
    role: .dashboard,
    preference: .system,
    tabTitle: "",
    pendingDecisionCount: 0,
    pendingDecisionSeverity: nil
  )
  private var pendingTabbingTask: Task<Void, Never>?
  private var notificationTokens: [NSObjectProtocol] = []

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    registerWindowObservers()
    scheduleWindowTabbingApplication()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    scheduleWindowTabbingApplication()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    cancelWindowTabbingUpdates()
  }

  private func registerWindowObservers() {
    guard let window else { return }
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ]
    notificationTokens = names.map { name in
      center.addObserver(
        forName: name,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.scheduleWindowTabbingApplication()
        }
      }
    }
  }

  private func tearDownWindowObservers() {
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    notificationTokens.removeAll()
  }

  func scheduleWindowTabbingApplication() {
    pendingTabbingTask?.cancel()
    pendingTabbingTask = Task { @MainActor [weak self] in
      await Task.yield()
      self?.applyWindowTabbing()
    }
  }

  func cancelWindowTabbingUpdates() {
    pendingTabbingTask?.cancel()
    tearDownWindowObservers()
  }

  func applyWindowTabbing() {
    guard let window else {
      return
    }
    // AppKit groups restored windows by `tabbingIdentifier`; SwiftUI's unified
    // toolbar can attach later than the NSWindow itself during restoration, so
    // tab identity must be installed before toolbar chrome is ready.
    SessionWindowTabbingSupport.prepareWindowForTabbing(
      window,
      preference: configuration.preference
    )
    guard window.tabbingIdentifier == SessionWindowTabbingSupport.tabbingIdentifier else {
      Self.log.warning(
        "Shared tabbing identifier unavailable; falling back to standalone windows")
      window.tabbingMode = .automatic
      return
    }
    if configuration.role == .session {
      applyTabBadge(on: window)
    }
    applyTitlebarChromeOverrides(to: window)
  }

  private func applyTabBadge(on window: NSWindow) {
    window.tab.attributedTitle = SessionWindowTabBadge.attributedTitle(
      base: configuration.tabTitle,
      pendingDecisionCount: configuration.pendingDecisionCount,
      severity: configuration.pendingDecisionSeverity
    )
  }

  /// `NSWindowTab` properties are configurable before a window visibly joins a
  /// tab strip, and AppKit can re-apply its titlebar defaults whenever tabs are
  /// added or removed, so keep reasserting the override on window updates. The
  /// transparent titlebar lets the unified toolbar sample the banner/detail
  /// chrome beneath it instead of falling back to AppKit's opaque fill.
  private func applyTitlebarChromeOverrides(to window: NSWindow) {
    window.titlebarSeparatorStyle = .none
    window.titlebarAppearsTransparent = true
  }
}
