import SwiftUI

@Observable
@MainActor
public final class WindowNavigationState {
  @ObservationIgnored
  private var storedCanGoBack = false
  @ObservationIgnored
  private var storedCanGoForward = false

  public var canGoBack: Bool {
    get {
      access(keyPath: \.canGoBack)
      return storedCanGoBack
    }
    set {
      guard storedCanGoBack != newValue else {
        return
      }
      withMutation(keyPath: \.canGoBack) {
        storedCanGoBack = newValue
      }
    }
  }

  public var canGoForward: Bool {
    get {
      access(keyPath: \.canGoForward)
      return storedCanGoForward
    }
    set {
      guard storedCanGoForward != newValue else {
        return
      }
      withMutation(keyPath: \.canGoForward) {
        storedCanGoForward = newValue
      }
    }
  }

  @ObservationIgnored
  var backHandler: (@MainActor () async -> Void)?
  @ObservationIgnored
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
