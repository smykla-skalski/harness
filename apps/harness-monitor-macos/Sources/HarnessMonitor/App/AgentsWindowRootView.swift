import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

private enum AgentsWindowMounting {
  static let firstFrameDelay: Duration = .milliseconds(60)
}

struct AgentsWindowRootView: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let acpAttentionState: AcpPermissionAttentionState
  let navigationBridge: AgentsWindowNavigationBridge
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
      case .agents:
        "agents"
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
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentsWindow)
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
          scope: .agents,
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
      AgentsWindowView(store: store, navigationBridge: navigationBridge)
    } else {
      AgentsWindowOpeningView()
    }
  }

  @ViewBuilder private var commandRoutingMarker: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.agentsCommandRoutingState,
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
    try? await Task.sleep(for: AgentsWindowMounting.firstFrameDelay)
    guard !Task.isCancelled else {
      return
    }
    showsWorkspaceContent = true
  }
}

private struct AgentsWindowOpeningView: View {
  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      ProgressView()
        .controlSize(.small)
      Text("Opening workspace")
        .scaledFont(.headline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Opening workspace")
  }
}
