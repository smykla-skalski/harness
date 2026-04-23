import HarnessMonitorUIPreviewable
import SwiftUI

@MainActor
final class HarnessMonitorMainWindowLauncher {
  static let shared = HarnessMonitorMainWindowLauncher()
  var openMainWindow: (() -> Void)?
  private init() {}
}

struct HarnessMonitorMainWindowLauncherBinder: ViewModifier {
  @Environment(\.openWindow)
  private var openWindow

  func body(content: Content) -> some View {
    content.onAppear {
      HarnessMonitorMainWindowLauncher.shared.openMainWindow = {
        openWindow(id: HarnessMonitorWindowID.main)
      }
    }
  }
}
