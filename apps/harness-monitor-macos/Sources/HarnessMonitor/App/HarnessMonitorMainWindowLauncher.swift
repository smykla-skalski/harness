@MainActor
final class HarnessMonitorMainWindowLauncher {
  static let shared = HarnessMonitorMainWindowLauncher()
  private var openMainWindow: (() -> Void)?
  private var hasPendingOpenRequest = false
  private init() {}

  func requestOpenMainWindow() {
    guard let openMainWindow else {
      hasPendingOpenRequest = true
      return
    }
    openMainWindow()
  }

  func installOpenMainWindow(_ openMainWindow: @escaping () -> Void) {
    self.openMainWindow = openMainWindow
    guard hasPendingOpenRequest else {
      return
    }
    hasPendingOpenRequest = false
    openMainWindow()
  }

  var hasPendingOpenRequestForTesting: Bool {
    hasPendingOpenRequest
  }

  func resetForTesting() {
    openMainWindow = nil
    hasPendingOpenRequest = false
  }
}
