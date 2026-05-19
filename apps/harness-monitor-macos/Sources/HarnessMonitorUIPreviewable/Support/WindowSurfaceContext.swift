import SwiftUI

public struct WindowSurfaceContext: Equatable, Sendable {
  public let windowID: String
  public let isKeyWindow: Bool
  public let navigationScope: WindowNavigationScope?
  public let openWindow: @MainActor @Sendable (String) -> Void
  private let openMainWindowAction: (@MainActor @Sendable () -> Void)?

  public init(
    windowID: String = "",
    isKeyWindow: Bool = true,
    navigationScope: WindowNavigationScope? = nil,
    openWindow: @escaping @MainActor @Sendable (String) -> Void = { _ in },
    openMainWindow: (@MainActor @Sendable () -> Void)? = nil
  ) {
    self.windowID = windowID
    self.isKeyWindow = isKeyWindow
    self.navigationScope = navigationScope
    self.openWindow = openWindow
    openMainWindowAction = openMainWindow
  }

  @MainActor
  public func openMainWindow() {
    if let openMainWindowAction {
      openMainWindowAction()
    } else {
      openWindow(HarnessMonitorWindowID.dashboard)
    }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.windowID == rhs.windowID
      && lhs.isKeyWindow == rhs.isKeyWindow
      && lhs.navigationScope == rhs.navigationScope
  }
}

public struct OpenTaskBoardSettingsAction: Sendable {
  private let action: @MainActor @Sendable (SettingsTaskBoardAnchor) -> Void

  public init(
    _ action: @escaping @MainActor @Sendable (SettingsTaskBoardAnchor) -> Void = { _ in }
  ) {
    self.action = action
  }

  @MainActor
  public func callAsFunction(_ anchor: SettingsTaskBoardAnchor = .githubProject) {
    action(anchor)
  }
}

private struct OpenTaskBoardSettingsActionKey: EnvironmentKey {
  static let defaultValue = OpenTaskBoardSettingsAction()
}

private struct WindowSurfaceContextKey: EnvironmentKey {
  static let defaultValue = WindowSurfaceContext()
}

extension EnvironmentValues {
  public var openTaskBoardSettings: OpenTaskBoardSettingsAction {
    get { self[OpenTaskBoardSettingsActionKey.self] }
    set { self[OpenTaskBoardSettingsActionKey.self] = newValue }
  }

  public var windowSurfaceContext: WindowSurfaceContext {
    get { self[WindowSurfaceContextKey.self] }
    set { self[WindowSurfaceContextKey.self] = newValue }
  }
}
