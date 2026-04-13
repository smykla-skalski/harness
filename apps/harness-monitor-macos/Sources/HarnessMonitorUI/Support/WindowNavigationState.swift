import SwiftUI

@Observable
@MainActor
public final class WindowNavigationState {
  public var canGoBack = false
  public var canGoForward = false

  var backHandler: (@MainActor () async -> Void)?
  var forwardHandler: (@MainActor () async -> Void)?

  public init() {}

  public func navigateBack() async {
    await backHandler?()
  }

  public func navigateForward() async {
    await forwardHandler?()
  }
}

extension FocusedValues {
  @Entry public var windowNavigation: WindowNavigationState?
}
