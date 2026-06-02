import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
import HarnessMonitorUIPreviewable
import SwiftUI

struct PolicyCanvasLabSceneHost: View {
  private static let minimumSize = CGSize(width: 0, height: 620)

  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  let allowsLiveBootstrap: Bool
  @Binding var themeMode: HarnessMonitorThemeMode

  var body: some View {
    let liveSnapshot = store.policyCanvasSnapshot
    HarnessMonitorWindowShell(
      windowID: HarnessMonitorWindowID.policyCanvasLab,
      windowTitle: "Policy Canvas Lab",
      scope: .main,
      minimumSize: Self.minimumSize,
      keyWindowObserver: keyWindowObserver,
      windowCommandRouting: windowCommandRouting,
      mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
      themeMode: $themeMode,
      appliesPreferredColorScheme: true,
      windowToolbarBackgroundVisibility: .automatic,
      toast: nil,
      handlesPinchToZoomTextSize: false,
      appliesWindowBackdrop: false,
      tracksWindowCommandScope: false,
      installsMCPWindowCommands: false
    ) {
      PolicyCanvasLabWindowView(
        liveSnapshot: liveSnapshot,
        runtime: store,
        allowsLiveBootstrap: allowsLiveBootstrap
      )
    }
  }
}
