import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct WorkspaceWindowRootView: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let acpAttentionState: AcpPermissionAttentionState
  let navigationBridge: WorkspaceWindowNavigationBridge
  let windowCommandRouting: WindowCommandRoutingState
  @Binding var themeMode: HarnessMonitorThemeMode
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue
  @State private var showsWorkspaceContent = false

  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }

  private var backgroundImage: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }

  private var commandRoutingStateText: String {
    let scopeLabel =
      switch windowCommandRouting.activeScope {
      case .workspace:
        "workspace"
      case .main:
        "main"
      case nil:
        "nil"
      }
    return [
      "scope=\(scopeLabel)",
      "canGoBack=\(navigationBridge.state.canGoBack)",
      "canGoForward=\(navigationBridge.state.canGoForward)",
    ].joined(separator: ",")
  }

  var body: some View {
    rootContent
      .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceWindow)
      .writingToolsBehavior(.disabled)
      .frame(minWidth: 1_020, minHeight: 680)
      .modifier(
        HarnessMonitorWindowBackdropModifier(
          mode: backdropMode,
          backgroundImage: backgroundImage
        )
      )
      .modifier(
        WindowCommandScopeTrackingModifier(
          scope: .workspace,
          routingState: windowCommandRouting
        )
      )
      .instantFocusRing()
      .modifier(
        HarnessMonitorSceneAppearanceModifier(
          themeMode: $themeMode,
          appliesPreferredColorScheme: true
        )
      )
      .modifier(PinchToZoomTextSizeModifier())
      .modifier(HarnessMonitorUITestAnimationModifier())
      .overlay { commandRoutingMarker }
      .task { await revealWorkspaceContentIfNeeded() }
  }

  @ViewBuilder private var rootContent: some View {
    if showsWorkspaceContent {
      WorkspaceWindowView(store: store, navigationBridge: navigationBridge)
    } else {
      WorkspaceWindowOpeningView()
    }
  }

  @ViewBuilder private var commandRoutingMarker: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.workspaceCommandRoutingState,
        text: commandRoutingStateText
      )
    }
  }

  @MainActor
  private func revealWorkspaceContentIfNeeded() async {
    guard !showsWorkspaceContent else {
      return
    }

    // Let AppKit commit the shell window before mounting the heavier workspace view tree.
    await Task.yield()
    guard !Task.isCancelled else {
      return
    }
    showsWorkspaceContent = true
  }
}
