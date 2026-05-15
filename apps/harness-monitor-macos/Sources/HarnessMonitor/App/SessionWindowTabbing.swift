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

private struct SessionWindowTabbingAccessor: NSViewRepresentable {
  struct Configuration: Equatable {
    let role: SessionWindowTabbing.Role
    let preference: SessionWindowTabbingPreference
    let tabTitle: String
    let pendingDecisionCount: Int
    let pendingDecisionSeverity: DecisionSeverity?
  }

  let configuration: Configuration

  func makeNSView(context: Context) -> AccessorView {
    let view = AccessorView()
    view.configuration = configuration
    return view
  }

  func updateNSView(_ nsView: AccessorView, context: Context) {
    nsView.configuration = configuration
    nsView.scheduleWindowTabbingApplication()
  }

  static func dismantleNSView(_ nsView: AccessorView, coordinator: ()) {
    nsView.cancelWindowTabbingUpdates()
  }
}

private final class AccessorView: NSView {
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
    guard window.toolbar != nil else {
      return
    }
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

  /// Setting `tabbingIdentifier` flips AppKit into a tabbable-window toolbar
  /// mode that draws an opaque titlebar with a baseline separator under the
  /// tab strip, masking the Liquid Glass blur in the unified toolbar. AppKit
  /// also re-applies its defaults whenever a new tab is added or removed, so
  /// the override has to run again on every change.
  private func applyTitlebarChromeOverrides(to window: NSWindow) {
    window.titlebarSeparatorStyle = .none
  }
}
