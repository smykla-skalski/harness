import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct WorkspaceWindowRootView: View {
  private static let contentRevealMinimumSize = CGSize(width: 1_020, height: 680)
  private static let contentRevealPollAttempts = 40
  private static let contentRevealPollInterval = Duration.milliseconds(25)

  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver
  let notifications: HarnessMonitorUserNotificationController
  let acpAttentionState: AcpPermissionAttentionState
  let navigationBridge: WorkspaceWindowNavigationBridge
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @Binding var themeMode: HarnessMonitorThemeMode
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current
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
      .harnessMonitorMCPWindowCommands(registrar: mcpWindowCommandRegistrar)
      .modifier(
        OptionalInstantFocusRingModifier(
          isEnabled: toolbarGlassReproConfiguration.usesInstantFocusRing
        )
      )
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
      WorkspaceWindowView(
        store: store,
        navigationBridge: navigationBridge
      )
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

    // Wait for AppKit to finish creating and sizing the shell window before
    // mounting the heavier split-view tree. Opening into a 0x0 window frame
    // triggers AttributeGraph churn on the first workspace layout pass.
    for _ in 0..<Self.contentRevealPollAttempts {
      await Task.yield()
      guard !Task.isCancelled else {
        return
      }
      if Self.workspaceWindowHasStableFrame() {
        showsWorkspaceContent = true
        return
      }
      try? await Task.sleep(for: Self.contentRevealPollInterval)
    }

    showsWorkspaceContent = true
  }

  private static func workspaceWindowHasStableFrame() -> Bool {
    guard let window = workspaceWindow() else {
      return false
    }
    let frame = window.frame
    return
      window.isVisible
      && !window.isMiniaturized
      && frame.width >= contentRevealMinimumSize.width
      && frame.height >= contentRevealMinimumSize.height
  }

  private static func workspaceWindow() -> NSWindow? {
    NSApplication.shared.windows.first { window in
      let identifier = window.identifier?.rawValue ?? ""
      return KeyWindowObserver.matchesWindowID(
        identifier,
        expected: HarnessMonitorWindowID.workspace
      )
    }
  }

}
