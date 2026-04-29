import AppKit
import Foundation
import Observation

public struct KeyWindowState: Equatable, Sendable {
  public let identifier: String?
  public let isVisible: Bool
  public let isMiniaturized: Bool

  public init(
    identifier: String?,
    isVisible: Bool,
    isMiniaturized: Bool
  ) {
    self.identifier = identifier
    self.isVisible = isVisible
    self.isMiniaturized = isMiniaturized
  }
}

@MainActor
public protocol KeyWindowObservableApplication: AnyObject {
  var keyWindowIdentifier: String? { get }
  var isActive: Bool { get }
  var isHidden: Bool { get }
  var windowStates: [KeyWindowState] { get }
}

extension NSApplication: KeyWindowObservableApplication {
  public var keyWindowIdentifier: String? {
    keyWindow?.identifier?.rawValue
  }

  public var windowStates: [KeyWindowState] {
    windows.map { window in
      KeyWindowState(
        identifier: window.identifier?.rawValue,
        isVisible: window.isVisible,
        isMiniaturized: window.isMiniaturized
      )
    }
  }
}

public struct KeyWindowSnapshot: Equatable, Sendable {
  public let keyWindowIdentifier: String?
  public let isAppActive: Bool
  public let appIsHidden: Bool
  public let hasVisibleNonMiniaturizedWindows: Bool

  public init(
    keyWindowIdentifier: String?,
    isAppActive: Bool,
    appIsHidden: Bool,
    hasVisibleNonMiniaturizedWindows: Bool
  ) {
    self.keyWindowIdentifier = keyWindowIdentifier
    self.isAppActive = isAppActive
    self.appIsHidden = appIsHidden
    self.hasVisibleNonMiniaturizedWindows = hasVisibleNonMiniaturizedWindows
  }

  public var prefersUserNotificationDelivery: Bool {
    appIsHidden || !isAppActive || !hasVisibleNonMiniaturizedWindows || keyWindowIdentifier == nil
  }

  public var routingToken: String {
    [
      "key=\(keyWindowIdentifier ?? "nil")",
      "active=\(isAppActive)",
      "hidden=\(appIsHidden)",
      "visible=\(hasVisibleNonMiniaturizedWindows)",
    ].joined(separator: ",")
  }
}

@MainActor
@Observable
public final class KeyWindowObserver {
  public private(set) var snapshot: KeyWindowSnapshot

  @ObservationIgnored private weak var application: (any KeyWindowObservableApplication)?
  @ObservationIgnored private let notificationCenter: NotificationCenter
  @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []

  public init(
    application: any KeyWindowObservableApplication = NSApplication.shared,
    notificationCenter: NotificationCenter = .default
  ) {
    self.application = application
    self.notificationCenter = notificationCenter
    self.snapshot = Self.snapshot(for: application)
    beginObserving()
    refresh()
  }

  deinit {
    MainActor.assumeIsolated {
      notificationTokens.forEach(notificationCenter.removeObserver)
    }
  }

  public func refresh() {
    guard let application else {
      snapshot = KeyWindowSnapshot(
        keyWindowIdentifier: nil,
        isAppActive: false,
        appIsHidden: false,
        hasVisibleNonMiniaturizedWindows: false
      )
      return
    }
    snapshot = Self.snapshot(for: application)
  }

  public func isKey(windowID: String) -> Bool {
    guard let keyWindowIdentifier = snapshot.keyWindowIdentifier else {
      return false
    }
    return Self.matchesWindowID(keyWindowIdentifier, expected: windowID)
  }

  private func beginObserving() {
    let names: [Notification.Name] = [
      NSApplication.didBecomeActiveNotification,
      NSApplication.didResignActiveNotification,
      NSApplication.didHideNotification,
      NSApplication.didUnhideNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.willCloseNotification,
    ]
    notificationTokens = names.map { name in
      notificationCenter.addObserver(
        forName: name,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.refresh()
        }
      }
    }
  }

  private static func snapshot(
    for application: any KeyWindowObservableApplication
  ) -> KeyWindowSnapshot {
    let hasVisibleNonMiniaturizedWindows = application.windowStates.contains { window in
      window.isVisible && !window.isMiniaturized
    }
    return KeyWindowSnapshot(
      keyWindowIdentifier: application.keyWindowIdentifier,
      isAppActive: application.isActive,
      appIsHidden: application.isHidden,
      hasVisibleNonMiniaturizedWindows: hasVisibleNonMiniaturizedWindows
    )
  }

  public static func matchesWindowID(_ actual: String, expected: String) -> Bool {
    guard !expected.isEmpty else {
      return false
    }
    if actual == expected {
      return true
    }
    let separators = CharacterSet.alphanumerics.inverted
    return actual
      .components(separatedBy: separators)
      .contains(expected)
  }
}
