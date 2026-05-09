import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct WindowBackdropConfiguration {
  let mode: HarnessMonitorBackdropMode
  let backgroundImage: HarnessMonitorBackgroundSelection

  var accessibilityValue: String {
    mode.rawValue
  }
}

struct WindowContentReadiness {
  let isReady: Bool
  let stateLabel: String
  let placeholder: WindowContentReadinessPlaceholder
  let prepare: @MainActor () async -> Void

  static func ready(stateLabel: String = "ready") -> Self {
    Self(
      isReady: true,
      stateLabel: stateLabel,
      placeholder: .clear,
      prepare: {}
    )
  }
}

@MainActor
enum WindowContentReadinessPlaceholder {
  case clear
  case workspaceOpening

  @ViewBuilder var body: some View {
    switch self {
    case .clear:
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    case .workspaceOpening:
      WorkspaceWindowOpeningView()
    }
  }
}

struct HarnessMonitorWindowShell<Content: View>: View {
  let windowID: String
  let windowTitle: String
  let scope: WindowNavigationScope
  let minimumSize: CGSize
  let accessibilityIdentifier: String?
  let keyWindowObserver: KeyWindowObserver?
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  let contentReadiness: WindowContentReadiness
  let preferredColorSchemeOverride: Bool?
  private let toast: ToastSlice?
  private let content: Content
  @Binding private var themeMode: HarnessMonitorThemeMode
  @Environment(\.openWindow)
  private var openWindow
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  init(
    windowID: String,
    windowTitle: String,
    scope: WindowNavigationScope,
    minimumSize: CGSize,
    accessibilityIdentifier: String? = nil,
    keyWindowObserver: KeyWindowObserver? = nil,
    windowCommandRouting: WindowCommandRoutingState,
    mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar,
    themeMode: Binding<HarnessMonitorThemeMode>,
    contentReadiness: WindowContentReadiness = .ready(),
    appliesPreferredColorScheme: Bool? = nil,
    toast: ToastSlice? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.windowID = windowID
    self.windowTitle = windowTitle
    self.scope = scope
    self.minimumSize = minimumSize
    self.accessibilityIdentifier = accessibilityIdentifier
    self.keyWindowObserver = keyWindowObserver
    self.windowCommandRouting = windowCommandRouting
    self.mcpWindowCommandRegistrar = mcpWindowCommandRegistrar
    _themeMode = themeMode
    self.contentReadiness = contentReadiness
    preferredColorSchemeOverride = appliesPreferredColorScheme
    self.toast = toast
    self.content = content()
  }

  private var backdrop: WindowBackdropConfiguration {
    WindowBackdropConfiguration(
      mode: HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none,
      backgroundImage: HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
    )
  }

  private var appliesPreferredColorScheme: Bool {
    preferredColorSchemeOverride ?? !toolbarGlassReproConfiguration.disablesPreferredColorScheme
  }

  private var surfaceContext: WindowSurfaceContext {
    WindowSurfaceContext(
      windowID: windowID,
      isKeyWindow: keyWindowObserver?.isKey(windowID: windowID) ?? true,
      navigationScope: scope,
      openWindow: { windowID in
        openWindow(id: windowID)
      }
    )
  }

  var body: some View {
    WindowContentReadinessGate(readiness: contentReadiness) {
      content
    }
    .modifier(OptionalAccessibilityIdentifierModifier(identifier: accessibilityIdentifier))
    .writingToolsBehavior(.disabled)
    .frame(
      minWidth: minimumSize.width,
      maxWidth: .infinity,
      minHeight: minimumSize.height,
      maxHeight: .infinity
    )
    .modifier(
      HarnessMonitorSceneAppearanceModifier(
        themeMode: $themeMode,
        appliesPreferredColorScheme: appliesPreferredColorScheme
      )
    )
    .modifier(PinchToZoomTextSizeModifier())
    .modifier(
      HarnessMonitorWindowBackdropModifier(
        mode: backdrop.mode,
        backgroundImage: backdrop.backgroundImage
      )
    )
    .modifier(
      WindowCommandScopeTrackingModifier(
        scope: scope,
        routingState: windowCommandRouting
      )
    )
    .harnessMonitorMCPWindowCommands(registrar: mcpWindowCommandRegistrar)
    .modifier(HarnessMonitorUITestAnimationModifier())
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
    .environment(\.windowSurfaceContext, surfaceContext)
    .overlay(alignment: .topTrailing) { toastOverlay }
    .overlay { shellStateMarker }
  }

  @ViewBuilder private var toastOverlay: some View {
    if let toast, !toast.activeFeedback.isEmpty {
      HarnessMonitorFeedbackToastView(toast: toast)
        .padding(.top, HarnessMonitorTheme.spacingSM)
        .padding(.trailing, HarnessMonitorTheme.spacingLG)
    }
  }

  @ViewBuilder private var shellStateMarker: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.windowShellState(windowID),
        text: [
          "windowID=\(windowID)",
          "title=\(windowTitle)",
          "shell=shared",
          "minSize=\(Int(minimumSize.width))x\(Int(minimumSize.height))",
          "commandRouting=window-scoped",
          "navigationScope=tracked",
          "backdrop=\(backdrop.accessibilityValue)",
          "toolbarBackground=automatic",
          "preferredColorScheme=\(appliesPreferredColorScheme ? "enabled" : "disabled")",
          "contentReadiness=\(contentReadiness.stateLabel)",
          "mcpCommands=shared",
          "writingTools=disabled",
          "animationPolicy=ui-test-aware",
          "bannerChrome=shared",
        ].joined(separator: ", ")
      )
    }
  }
}

private struct WindowContentReadinessGate<Content: View>: View {
  let readiness: WindowContentReadiness
  let content: Content

  init(
    readiness: WindowContentReadiness,
    @ViewBuilder content: () -> Content
  ) {
    self.readiness = readiness
    self.content = content()
  }

  var body: some View {
    if readiness.isReady {
      content
    } else {
      readiness.placeholder.body
        .task {
          await readiness.prepare()
        }
    }
  }
}

private struct OptionalAccessibilityIdentifierModifier: ViewModifier {
  let identifier: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let identifier {
      content.accessibilityIdentifier(identifier)
    } else {
      content
    }
  }
}
