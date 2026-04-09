import HarnessMonitorKit
import Observation
import SwiftUI

@MainActor
@Observable
public final class SidebarSearchController {
  public var focusRequestToken = 0

  public init() {}

  public func requestFocus() {
    focusRequestToken &+= 1
  }
}

public struct ContentView: View {
  let store: HarnessMonitorStore
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  let searchController: SidebarSearchController
  @Environment(\.openWindow)
  private var openWindow
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @AppStorage("showInspector")
  private var showInspector = true
  @AppStorage("inspectorColumnWidth")
  private var inspectorColumnWidth: Double = HarnessMonitorInspectorLayout.idealWidth
  @SceneStorage("selectedSessionID")
  private var restoredSessionID: String?
  @State private var showLlama = false
  @State private var detailColumnWidth: CGFloat = 980
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var windowTitle: String {
    contentUI.windowTitle
  }

  private var appChromeAccessibilityValue: String {
    [
      "contentChrome=native",
      "interactiveRows=list",
      "controlGlass=native",
    ].joined(separator: ", ")
  }

  private var toolbarChromeAccessibilityValue: String {
    [
      "toolbarTitle=native-window",
      "windowTitle=\(windowTitle)",
    ].joined(separator: ", ")
  }

  private var detailAvailableWidth: CGFloat { max(detailColumnWidth, 320) }

  // Quantize resize-driven updates so the principal toolbar does not recompute
  // on every pixel delta while the split view divider is dragged.
  private var toolbarDetailWidth: CGFloat {
    (detailAvailableWidth / 10).rounded() * 10
  }

  private var toolbarCenterpieceDisplayMode: ToolbarCenterpieceDisplayMode {
    ToolbarCenterpieceDisplayMode.forDetailWidth(detailAvailableWidth)
  }

  public init(store: HarnessMonitorStore, searchController: SidebarSearchController) {
    self.store = store
    self.contentUI = store.contentUI
    self.searchController = searchController
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarView(
        store: store,
        sessionIndex: store.sessionIndex,
        searchController: searchController
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
      .toolbarBaselineFrame(.sidebar)
    } detail: {
      ContentDetailColumn(
        store: store,
        contentUI: contentUI,
        showInspector: $showInspector,
        toolbarGlassReproConfiguration: toolbarGlassReproConfiguration,
        openPreferences: openPreferences,
        refresh: refresh,
        detailWidthChanged: { width in
          guard abs(width - detailColumnWidth) >= 1 else {
            return
          }
          detailColumnWidth = width
        }
      )
    }
    .navigationSplitViewStyle(.prominentDetail)
    .inspector(isPresented: $showInspector) {
      InspectorColumnView(store: store, inspectorUI: store.inspectorUI)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.width
        } action: { width in
          guard showInspector,
                width >= HarnessMonitorInspectorLayout.minWidth,
                width <= HarnessMonitorInspectorLayout.maxWidth,
                abs(width - inspectorColumnWidth) > 1
          else {
            return
          }
          inspectorColumnWidth = width
        }
        .inspectorColumnWidth(
          min: HarnessMonitorInspectorLayout.minWidth,
          ideal: inspectorColumnWidth,
          max: HarnessMonitorInspectorLayout.maxWidth
        )
    }
    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .navigationTitle(windowTitle)
    .background { CommandsDisplayStatePublisher(store: store) }
    .toolbar {
      ContentNavigationToolbarItems(
        store: store,
        navigateBack: navigateBack,
        navigateForward: navigateForward
      )
      ContentCenterpieceToolbarItems(
        store: store,
        displayMode: toolbarCenterpieceDisplayMode,
        availableDetailWidth: toolbarDetailWidth,
        showLlama: $showLlama,
        toggleSleepPrevention: toggleSleepPrevention
      )
    }
    .onAppear {
      if let restoredSessionID, contentUI.selectedSessionID == nil {
        Task { await store.selectSession(restoredSessionID) }
      }
    }
    .onChange(of: contentUI.selectedSessionID) { _, newID in
      restoredSessionID = newID
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.appChromeRoot)
    .overlay {
      ZStack {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.appChromeState,
          text: appChromeAccessibilityValue
        )
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.toolbarChromeState,
          text: toolbarChromeAccessibilityValue
        )
        ContentToolbarAccessibilityMarker(store: store)
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.toolbarCenterpieceMode,
          text: toolbarCenterpieceDisplayMode.rawValue
        )
      }
    }
    .modifier(
      OptionalToolbarBaselineOverlayModifier(
        isEnabled: !toolbarGlassReproConfiguration.disablesToolbarBaselineOverlay
      )
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .harnessCornerAnimation(
      .dancingLlama,
      isPresented: showLlama
        || contentUI.isSelectionLoading
        || contentUI.isExtensionsLoading
        || contentUI.isRefreshing
        || contentUI.connectionState == .connecting,
      presentationDelay: showLlama ? nil : .milliseconds(400)
    )
    .modifier(
      HarnessMonitorConfirmationDialogModifier(
        store: store,
        pendingConfirmation: contentUI.pendingConfirmation
      )
    )
    .modifier(
      HarnessMonitorSheetModifier(
        store: store,
        presentedSheet: contentUI.presentedSheet
      )
    )
    .modifier(
      ContentAnnouncementsModifier(
        connectionState: contentUI.connectionState,
        lastAction: contentUI.lastAction
      )
    )
  }

  private func openPreferences() {
    openWindow(id: HarnessMonitorWindowID.preferences)
  }

  func navigateBack() {
    Task { await store.navigateBack() }
  }

  func navigateForward() {
    Task { await store.navigateForward() }
  }

  func refresh() {
    Task { await store.refresh() }
  }

  func toggleSleepPrevention() {
    store.sleepPreventionEnabled.toggle()
  }
}

private struct ContentDetailColumn: View {
  let store: HarnessMonitorStore
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @Binding var showInspector: Bool
  let toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration
  let openPreferences: () -> Void
  let refresh: () -> Void
  let detailWidthChanged: (CGFloat) -> Void

  init(
    store: HarnessMonitorStore,
    contentUI: HarnessMonitorStore.ContentUISlice,
    showInspector: Binding<Bool>,
    toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration,
    openPreferences: @escaping () -> Void,
    refresh: @escaping () -> Void,
    detailWidthChanged: @escaping (CGFloat) -> Void
  ) {
    self.store = store
    self.contentUI = contentUI
    self._showInspector = showInspector
    self.toolbarGlassReproConfiguration = toolbarGlassReproConfiguration
    self.openPreferences = openPreferences
    self.refresh = refresh
    self.detailWidthChanged = detailWidthChanged
  }

  var body: some View {
    ZStack {
      if toolbarGlassReproConfiguration.disablesContentDetailChrome {
        sessionContent
      } else {
        ContentDetailChrome(
          persistenceError: contentUI.persistenceError,
          sessionDataAvailability: contentUI.sessionDataAvailability,
          sessionStatus: contentUI.sessionStatus
        ) {
          sessionContent
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      detailWidthChanged(width)
    }
    .toolbar {
      ContentPrimaryToolbarItems(
        contentUI: contentUI,
        showInspector: $showInspector,
        openPreferences: openPreferences,
        refresh: refresh
      )
    }
  }

  private var sessionContent: some View {
    SessionContentContainer(
      store: store,
      state: SessionContentState(
        detail: contentUI.selectedDetail,
        summary: contentUI.selectedSessionSummary,
        timeline: contentUI.timeline,
        isSessionReadOnly: contentUI.isSessionReadOnly,
        isSessionActionInFlight: contentUI.isSessionActionInFlight,
        isSelectionLoading: contentUI.isSelectionLoading,
        isExtensionsLoading: contentUI.isExtensionsLoading,
        lastAction: contentUI.lastAction
      )
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.contentRoot).frame")
    .onKeyPress(.escape) {
      if store.inspectorUI.actionContext != nil {
        store.inspectorSelection = .none
        return .handled
      }
      return .ignored
    }
  }
}

private struct ContentNavigationToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let navigateBack: () -> Void
  let navigateForward: () -> Void

  var body: some ToolbarContent {
    ContentNavigationToolbar(
      canNavigateBack: store.canNavigateBack,
      canNavigateForward: store.canNavigateForward,
      navigateBack: navigateBack,
      navigateForward: navigateForward
    )
  }
}

private struct ContentCenterpieceToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let displayMode: ToolbarCenterpieceDisplayMode
  let availableDetailWidth: CGFloat
  @Binding var showLlama: Bool
  let toggleSleepPrevention: () -> Void

  var body: some ToolbarContent {
    ContentCenterpieceToolbar(
      model: store.toolbarCenterpieceModel,
      displayMode: displayMode,
      availableDetailWidth: availableDetailWidth,
      statusMessages: store.toolbarStatusMessages,
      daemonIndicator: store.toolbarDaemonIndicator
    )

    ToolbarItemGroup(placement: .principal) {
      Button(action: toggleSleepPrevention) {
        Label(
          store.sleepPreventionEnabled ? "Sleep Prevention On" : "Prevent Sleep",
          systemImage: store.sleepPreventionEnabled ? "moon.zzz.fill" : "moon.zzz"
        )
      }
      .tint(store.sleepPreventionEnabled ? .orange : nil)
      .help(
        store.sleepPreventionEnabled
          ? "Preventing sleep - click to disable"
          : "Allow sleep - click to prevent"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)

      Button { showLlama.toggle() } label: {
        Label(
          showLlama ? "Hide Llama" : "Show Llama",
          systemImage: showLlama ? "hare.fill" : "hare"
        )
      }
      .tint(showLlama ? .purple : nil)
      .help(showLlama ? "Hide dancing llama" : "Show dancing llama")
    }
    .sharedBackgroundVisibility(.hidden)
  }
}

private struct ContentPrimaryToolbarItems: ToolbarContent {
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @Binding var showInspector: Bool
  let openPreferences: () -> Void
  let refresh: () -> Void

  init(
    contentUI: HarnessMonitorStore.ContentUISlice,
    showInspector: Binding<Bool>,
    openPreferences: @escaping () -> Void,
    refresh: @escaping () -> Void
  ) {
    self.contentUI = contentUI
    self._showInspector = showInspector
    self.openPreferences = openPreferences
    self.refresh = refresh
  }

  var body: some ToolbarContent {
    InspectorToolbarActions(
      contentUI: contentUI,
      showInspector: $showInspector,
      openPreferences: openPreferences,
      refresh: refresh
    )
  }
}

struct InspectorToolbarActions: ToolbarContent {
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @Binding var showInspector: Bool
  let openPreferences: () -> Void
  let refresh: () -> Void

  init(
    contentUI: HarnessMonitorStore.ContentUISlice,
    showInspector: Binding<Bool>,
    openPreferences: @escaping () -> Void,
    refresh: @escaping () -> Void
  ) {
    self.contentUI = contentUI
    self._showInspector = showInspector
    self.openPreferences = openPreferences
    self.refresh = refresh
  }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      RefreshToolbarButton(isRefreshing: contentUI.isRefreshing, refresh: refresh)
        .help("Refresh sessions")

      Button(action: openPreferences) {
        Label("Settings", systemImage: "gearshape")
      }
      .help("Open settings")
      .accessibilityIdentifier(HarnessMonitorAccessibility.daemonPreferencesButton)
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItem(placement: .primaryAction) {
      Button { showInspector.toggle() } label: {
        Label(
          showInspector ? "Hide Inspector" : "Show Inspector",
          systemImage: "sidebar.trailing"
        )
      }
      .accessibilityLabel(showInspector ? "Hide Inspector" : "Show Inspector")
      .accessibilityIdentifier(HarnessMonitorAccessibility.inspectorToggleButton)
      .help(showInspector ? "Hide inspector" : "Show inspector")
    }
  }
}

private struct ContentToolbarAccessibilityMarker: View {
  let store: HarnessMonitorStore

  var body: some View {
    AccessibilityTextMarker(
      identifier: HarnessMonitorAccessibility.toolbarCenterpieceState,
      text: store.toolbarCenterpieceModel.accessibilityValue
    )
  }
}
