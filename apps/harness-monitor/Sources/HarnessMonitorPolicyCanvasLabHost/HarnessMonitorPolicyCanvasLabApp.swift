import HarnessMonitorPolicyCanvas
import SwiftUI

@main
struct HarnessMonitorPolicyCanvasLabApp: App {
  var body: some Scene {
    WindowGroup("Policy Canvas Lab") {
      PolicyCanvasLabWindowView()
        .frame(minWidth: 960, minHeight: 620)
    }
    .defaultSize(width: 1_440, height: 900)
    .windowResizability(.contentMinSize)
  }
}
