import AppKit
import HarnessMonitorPolicyCanvas
import SwiftUI

private final class HarnessMonitorPolicyCanvasLabAppDelegate: NSObject, NSApplicationDelegate {
  func application(
    _: NSApplication,
    shouldRestoreApplicationState _: NSCoder
  ) -> Bool {
    false
  }

  func application(
    _: NSApplication,
    shouldSaveApplicationState _: NSCoder
  ) -> Bool {
    false
  }
}

@main
struct HarnessMonitorPolicyCanvasLabApp: App {
  @NSApplicationDelegateAdaptor(HarnessMonitorPolicyCanvasLabAppDelegate.self)
  private var appDelegate

  var body: some Scene {
    WindowGroup("Policy Canvas Lab") {
      PolicyCanvasLabWindowView()
        .writingToolsBehavior(.disabled)
        .frame(minWidth: 960, minHeight: 620)
    }
    .defaultSize(width: 1_440, height: 900)
    .windowResizability(.contentMinSize)
    .restorationBehavior(.disabled)
  }
}
