import HarnessMonitorKit
import SwiftUI

public struct CommandsDisplayState: Equatable {
  public let canNavigateBack: Bool
  public let canNavigateForward: Bool
  public let hasSelectedSession: Bool
  public let isSessionReadOnly: Bool
  public let bookmarkTitle: String
  public let isPersistenceAvailable: Bool
  public let hasObserver: Bool
}

public enum HarnessMonitorInspectorLayout {
  public static let minWidth: CGFloat = 320
  public static let idealWidth: CGFloat = 420
  public static let maxWidth: CGFloat = 480
}

public enum ContentInspectorVisibilitySource {
  case persistedPreference
  case explicitUserPreference
  case contextualAutoOpen
  case framework
}

public struct ContentInspectorVisibilityChange: Equatable {
  public let nextPresentation: Bool
  public let persistedPreference: Bool?
  public let shouldSuppressLayoutGeometry: Bool
}

public enum ContentInspectorVisibilityPolicy {
  public static func resolve(
    currentPresentation: Bool,
    currentPersistedPreference: Bool,
    nextPresentation: Bool,
    source: ContentInspectorVisibilitySource
  ) -> ContentInspectorVisibilityChange? {
    let shouldPersistPreference: Bool
    let shouldSuppressLayoutGeometry: Bool

    switch source {
    case .persistedPreference:
      shouldPersistPreference = false
      shouldSuppressLayoutGeometry = currentPresentation != nextPresentation
    case .explicitUserPreference:
      shouldPersistPreference = currentPersistedPreference != nextPresentation
      shouldSuppressLayoutGeometry =
        currentPresentation != nextPresentation || shouldPersistPreference
    case .contextualAutoOpen:
      shouldPersistPreference = false
      shouldSuppressLayoutGeometry = currentPresentation != nextPresentation
    case .framework:
      shouldPersistPreference = false
      shouldSuppressLayoutGeometry = false
    }

    guard currentPresentation != nextPresentation || shouldPersistPreference else {
      return nil
    }

    return ContentInspectorVisibilityChange(
      nextPresentation: nextPresentation,
      persistedPreference: shouldPersistPreference ? nextPresentation : nil,
      shouldSuppressLayoutGeometry: shouldSuppressLayoutGeometry
    )
  }
}

// MARK: - Commands state

extension HarnessMonitorStore {
  // Keep Commands state as plain data. Startup command enablement now reads a
  // tracked key-window scope plus these snapshots instead of scene FocusedValue
  // propagation, which avoided same-frame update faults during launch.
  public var commandsDisplayState: CommandsDisplayState {
    CommandsDisplayState(
      canNavigateBack: canNavigateBack,
      canNavigateForward: canNavigateForward,
      hasSelectedSession: selectedSessionID != nil,
      isSessionReadOnly: isSessionReadOnly,
      bookmarkTitle: selectedSessionBookmarkTitle,
      isPersistenceAvailable: isPersistenceAvailable,
      hasObserver: selectedSession?.observer != nil
    )
  }
}

extension HarnessMonitorStore.ContentToolbarSlice {
  fileprivate var toolbarCenterpieceModel: ToolbarCenterpieceModel {
    ToolbarCenterpieceModel(
      workspaceName: "Harness Monitor",
      destinationName: "My Mac",
      destinationSystemImage: "laptopcomputer"
    )
  }

  fileprivate var toolbarStatusMessages: [ToolbarStatusMessage] {
    statusMessages.map(ToolbarStatusMessage.init)
  }
}

// MARK: - Content toolbar items

public struct ContentNavigationToolbarItems: ToolbarContent {
  public let store: HarnessMonitorStore
  public let toolbarUI: HarnessMonitorStore.ContentToolbarSlice

  public init(store: HarnessMonitorStore, toolbarUI: HarnessMonitorStore.ContentToolbarSlice) {
    self.store = store
    self.toolbarUI = toolbarUI
  }

  public var body: some ToolbarContent {
    ContentNavigationToolbar(
      store: store,
      canNavigateBack: toolbarUI.canNavigateBack,
      canNavigateForward: toolbarUI.canNavigateForward
    )
  }
}

public struct ContentCenterpieceToolbarItems: ToolbarContent {
  public let store: HarnessMonitorStore
  public let toolbarUI: HarnessMonitorStore.ContentToolbarSlice
  public let displayMode: ToolbarCenterpieceDisplayMode
  public let availableDetailWidth: CGFloat

  public init(
    store: HarnessMonitorStore,
    toolbarUI: HarnessMonitorStore.ContentToolbarSlice,
    displayMode: ToolbarCenterpieceDisplayMode,
    availableDetailWidth: CGFloat
  ) {
    self.store = store
    self.toolbarUI = toolbarUI
    self.displayMode = displayMode
    self.availableDetailWidth = availableDetailWidth
  }

  public var body: some ToolbarContent {
    ContentCenterpieceToolbar(
      model: toolbarUI.toolbarCenterpieceModel,
      displayMode: displayMode,
      availableDetailWidth: availableDetailWidth,
      statusMessages: toolbarUI.toolbarStatusMessages,
      connectionState: toolbarUI.connectionState
    )
  }
}

struct ContentPrimaryToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let toolbarUI: HarnessMonitorStore.ContentToolbarSlice
  let showInspector: Bool
  let setInspectorVisibility: (Bool, ContentInspectorVisibilitySource) -> Void

  var body: some ToolbarContent {
    InspectorToolbarActions(
      store: store,
      toolbarUI: toolbarUI,
      showInspector: showInspector,
      setInspectorVisibility: setInspectorVisibility
    )
  }
}

public struct ContentCornerOverlayModifier<CornerContent: View>: ViewModifier {
  public let isPresented: Bool
  public let cornerAnimationContent: CornerContent

  public init(isPresented: Bool, cornerAnimationContent: CornerContent) {
    self.isPresented = isPresented
    self.cornerAnimationContent = cornerAnimationContent
  }

  public func body(content: Content) -> some View {
    content
      .modifier(
        HarnessCornerOverlayModifier(
          isPresented: isPresented,
          configuration: .init(
            width: HarnessCornerAnimationDescriptor.dancingLlama.width,
            height: HarnessCornerAnimationDescriptor.dancingLlama.height,
            trailingPadding: HarnessCornerAnimationDescriptor.dancingLlama.trailingPadding,
            bottomPadding: HarnessCornerAnimationDescriptor.dancingLlama.bottomPadding,
            contentPadding: 0,
            appliesGlass: false,
            accessibilityLabel: HarnessCornerAnimationDescriptor.dancingLlama.accessibilityLabel,
            presentationDelay: nil
          )
        ) {
          cornerAnimationContent
        }
      )
  }
}

public struct ContentDetailColumn: View {
  public let store: HarnessMonitorStore
  public let toast: ToastSlice
  public let selection: HarnessMonitorStore.SelectionSlice
  public let contentChrome: HarnessMonitorStore.ContentChromeSlice
  public let contentSession: HarnessMonitorStore.ContentSessionSlice
  public let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice
  public let contentToolbar: HarnessMonitorStore.ContentToolbarSlice
  public let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  public let showInspector: Bool
  public let setInspectorVisibility: (Bool, ContentInspectorVisibilitySource) -> Void
  public let toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration
  public let onDetailColumnWidthChange: (CGFloat) -> Void

  public init(
    store: HarnessMonitorStore,
    toast: ToastSlice,
    selection: HarnessMonitorStore.SelectionSlice,
    contentChrome: HarnessMonitorStore.ContentChromeSlice,
    contentSession: HarnessMonitorStore.ContentSessionSlice,
    contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice,
    contentToolbar: HarnessMonitorStore.ContentToolbarSlice,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice,
    showInspector: Bool,
    setInspectorVisibility: @escaping (Bool, ContentInspectorVisibilitySource) -> Void,
    toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration,
    onDetailColumnWidthChange: @escaping (CGFloat) -> Void
  ) {
    self.store = store
    self.toast = toast
    self.selection = selection
    self.contentChrome = contentChrome
    self.contentSession = contentSession
    self.contentSessionDetail = contentSessionDetail
    self.contentToolbar = contentToolbar
    self.dashboardUI = dashboardUI
    self.showInspector = showInspector
    self.setInspectorVisibility = setInspectorVisibility
    self.toolbarGlassReproConfiguration = toolbarGlassReproConfiguration
    self.onDetailColumnWidthChange = onDetailColumnWidthChange
  }

  private var navigationTitleText: String {
    contentSessionDetail.presentedSessionDetail != nil ? "Session Cockpit" : "Dashboard"
  }

  private var navigationSubtitleText: String? {
    contentSessionDetail.presentedSessionDetail?.session.status.title.uppercased()
  }

  private var statusBackdropDetail: SessionDetail? {
    contentSessionDetail.presentedSessionDetail
  }

  public var body: some View {
    ZStack {
      if toolbarGlassReproConfiguration.disablesContentDetailChrome {
        sessionContent
      } else {
        ContentDetailChrome(
          persistenceError: contentChrome.persistenceError,
          sessionDataAvailability: contentChrome.sessionDataAvailability
        ) {
          sessionContent
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      onDetailColumnWidthChange(width)
    }
    .background(alignment: .topLeading) {
      if let detail = statusBackdropDetail {
        ContentStatusBackdrop(
          status: detail.session.status,
          isStale: contentChrome.sessionDataAvailability != .live
        )
      }
    }
    .toolbar {
      ContentPrimaryToolbarItems(
        store: store,
        toolbarUI: contentToolbar,
        showInspector: showInspector,
        setInspectorVisibility: setInspectorVisibility
      )
    }
    .navigationTitle(navigationTitleText)
    .navigationSubtitle(navigationSubtitleText ?? "")
    .onChange(of: selection.inspectorSelection) { _, newValue in
      if newValue != .none, !showInspector {
        setInspectorVisibility(true, .contextualAutoOpen)
      }
    }
  }

  private var sessionContent: some View {
    SessionContentContainer(
      store: store,
      dashboardUI: dashboardUI,
      state: SessionContentState(
        detail: contentSessionDetail.presentedSessionDetail,
        summary: contentSession.selectedSessionSummary,
        timeline: contentSessionDetail.presentedTimeline,
        timelineWindow: contentSessionDetail.presentedTimelineWindow,
        isSessionStatusStale: contentChrome.sessionDataAvailability != .live,
        isSessionReadOnly: contentSession.isSessionReadOnly,
        isSelectionLoading: contentSession.isSelectionLoading,
        isTimelineLoading: contentSessionDetail.isTimelineLoading,
        isExtensionsLoading: contentSession.isExtensionsLoading
      )
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.contentRoot).frame")
    .onKeyPress(.escape) {
      if let feedbackID = toast.activeFeedback.first?.id {
        toast.dismiss(id: feedbackID)
        return .handled
      }
      if contentSessionDetail.presentedSessionDetail != nil {
        store.inspectorSelection = .none
        return .handled
      }
      return .ignored
    }
  }
}

struct InspectorToolbarActions: ToolbarContent {
  let store: HarnessMonitorStore
  let toolbarUI: HarnessMonitorStore.ContentToolbarSlice
  let showInspector: Bool
  let setInspectorVisibility: (Bool, ContentInspectorVisibilitySource) -> Void

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        store.sleepPreventionEnabled.toggle()
      } label: {
        Label(
          toolbarUI.sleepPreventionEnabled ? "Sleep Prevention On" : "Prevent Sleep",
          systemImage: toolbarUI.sleepPreventionEnabled ? "moon.zzz.fill" : "moon.zzz"
        )
      }
      .tint(toolbarUI.sleepPreventionEnabled ? .orange : nil)
      .help(
        toolbarUI.sleepPreventionEnabled
          ? "Click to allow system sleep"
          : "Prevent sleep while sessions are active"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)

      RefreshToolbarButton(isRefreshing: toolbarUI.isRefreshing) {
        Task { await store.refresh() }
      }
      .help("Refresh sessions")
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItem(placement: .primaryAction) {
      Button {
        setInspectorVisibility(!showInspector, .explicitUserPreference)
      } label: {
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
