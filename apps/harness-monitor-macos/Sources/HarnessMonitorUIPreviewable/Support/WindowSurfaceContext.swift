import SwiftUI

public struct WindowSurfaceContext: Equatable, Sendable {
  public let windowID: String
  public let isKeyWindow: Bool
  public let navigationScope: WindowNavigationScope?
  public let openWindow: @MainActor @Sendable (String) -> Void

  public init(
    windowID: String = "",
    isKeyWindow: Bool = true,
    navigationScope: WindowNavigationScope? = nil,
    openWindow: @escaping @MainActor @Sendable (String) -> Void = { _ in }
  ) {
    self.windowID = windowID
    self.isKeyWindow = isKeyWindow
    self.navigationScope = navigationScope
    self.openWindow = openWindow
  }

  @MainActor
  public func openMainWindow() {
    openWindow(HarnessMonitorWindowID.dashboard)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.windowID == rhs.windowID
      && lhs.isKeyWindow == rhs.isKeyWindow
      && lhs.navigationScope == rhs.navigationScope
  }
}

private struct WindowSurfaceContextKey: EnvironmentKey {
  static let defaultValue = WindowSurfaceContext()
}

extension EnvironmentValues {
  public var windowSurfaceContext: WindowSurfaceContext {
    get { self[WindowSurfaceContextKey.self] }
    set { self[WindowSurfaceContextKey.self] = newValue }
  }
}
