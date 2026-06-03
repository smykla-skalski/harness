import HarnessMonitorPolicyCanvas
import SwiftUI

@main
struct HarnessMonitorPolicyCanvasLabApp: App {
  init() {
    #if DEBUG
    // Load the InjectionIII / InjectionNext bundle so source edits to the
    // layout and routing algorithms hot-reload into this running window.
    PolicyCanvasHotReload.loadInjectionBundle()
    #endif
  }

  var body: some Scene {
    WindowGroup("Policy Canvas Lab") {
      PolicyCanvasLabWindowView()
        .frame(minWidth: 960, minHeight: 620)
    }
    .defaultSize(width: 1_440, height: 900)
    .windowResizability(.contentMinSize)
  }
}
