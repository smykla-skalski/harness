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

enum HarnessMonitorInspectorLayout {
  static let minWidth: CGFloat = 320
  static let idealWidth: CGFloat = 420
  static let maxWidth: CGFloat = 480
}

// MARK: - Commands state

extension HarnessMonitorStore {
  // Keep Commands state as plain data. The scene-level FocusedValue bridge
  // emitted duplicate update faults during startup when the window toolbar
  // and command menu refreshed in the same frame.
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
    var metrics: [ToolbarCenterpieceMetric] = [
      .init(kind: .projects, value: toolbarMetrics.projectCount),
      .init(kind: .sessions, value: toolbarMetrics.sessionCount),
      .init(kind: .openWork, value: toolbarMetrics.openWorkCount),
      .init(kind: .blocked, value: toolbarMetrics.blockedCount),
    ]
    if toolbarMetrics.worktreeCount > 0 {
      metrics.insert(.init(kind: .worktrees, value: toolbarMetrics.worktreeCount), at: 1)
    }

    return ToolbarCenterpieceModel(
      workspaceName: "Harness Monitor",
      destinationName: "My Mac",
      destinationSystemImage: "laptopcomputer",
      metrics: metrics
    )
  }

  fileprivate var toolbarStatusMessages: [ToolbarStatusMessage] {
    statusMessages.map(ToolbarStatusMessage.init)
  }
}

// MARK: - Content toolbar items

struct ContentNavigationToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let toolbarUI: HarnessMonitorStore.ContentToolbarSlice

  var body: some ToolbarContent {
    ContentNavigationToolbar(
      store: store,
      canNavigateBack: toolbarUI.canNavigateBack,
      canNavigateForward: toolbarUI.canNavigateForward
    )
  }
}

struct ContentCenterpieceToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let toolbarUI: HarnessMonitorStore.ContentToolbarSlice
  let displayMode: ToolbarCenterpieceDisplayMode
  let availableDetailWidth: CGFloat

  var body: some ToolbarContent {
    ContentCenterpieceToolbar(
      model: toolbarUI.toolbarCenterpieceModel,
      displayMode: displayMode,
      availableDetailWidth: availableDetailWidth,
      statusMessages: toolbarUI.toolbarStatusMessages,
      connectionState: toolbarUI.connectionState
    )

    ToolbarItemGroup(placement: .principal) {
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
          ? "Preventing sleep - click to disable"
          : "Allow sleep - click to prevent"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)
    }
    .sharedBackgroundVisibility(.hidden)
  }
}

struct ContentPrimaryToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let toolbarUI: HarnessMonitorStore.ContentToolbarSlice
  @Binding var showInspector: Bool

  var body: some ToolbarContent {
    InspectorToolbarActions(
      store: store,
      toolbarUI: toolbarUI,
      showInspector: $showInspector
    )
  }
}

struct ContentToolbarAccessibilityMarker: View {
  let toolbarUI: HarnessMonitorStore.ContentToolbarSlice

  var body: some View {
    AccessibilityTextMarker(
      identifier: HarnessMonitorAccessibility.toolbarCenterpieceState,
      text: toolbarUI.toolbarCenterpieceModel.accessibilityValue
    )
  }
}

struct ContentCornerOverlayModifier: ViewModifier {
  let toolbarUI: HarnessMonitorStore.ContentToolbarSlice
  let cornerAnimationContent: () -> AnyView
  @AppStorage(HarnessMonitorCornerAnimationDefaults.enabledKey)
  private var cornerAnimationEnabled = false

  private var isPresented: Bool {
    cornerAnimationEnabled
      || toolbarUI.isRefreshing
      || toolbarUI.connectionState == .connecting
  }

  func body(content: Content) -> some View {
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
            presentationDelay: cornerAnimationEnabled ? nil : .milliseconds(400)
          )
        ) {
          cornerAnimationContent()
        }
      )
  }
}

struct ContentDetailColumn: View {
  let store: HarnessMonitorStore
  let toast: ToastSlice
  let selection: HarnessMonitorStore.SelectionSlice
  let contentChrome: HarnessMonitorStore.ContentChromeSlice
  let contentSession: HarnessMonitorStore.ContentSessionSlice
  let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice
  let contentToolbar: HarnessMonitorStore.ContentToolbarSlice
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  @Binding var showInspector: Bool
  let toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration
  let onDetailColumnWidthChange: (CGFloat) -> Void

  private var navigationTitleText: String {
    contentSessionDetail.presentedSessionDetail != nil ? "Cockpit" : "Dashboard"
  }

  var body: some View {
    ZStack {
      if toolbarGlassReproConfiguration.disablesContentDetailChrome {
        sessionContent
      } else {
        ContentDetailChrome(
          persistenceError: contentChrome.persistenceError,
          sessionDataAvailability: contentChrome.sessionDataAvailability,
          sessionStatus: contentChrome.sessionStatus
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
    .toolbar {
      ContentPrimaryToolbarItems(
        store: store,
        toolbarUI: contentToolbar,
        showInspector: $showInspector
      )
    }
    .navigationTitle(navigationTitleText)
    .onChange(of: selection.inspectorSelection) { _, newValue in
      if newValue != .none, !showInspector {
        showInspector = true
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
        isSessionReadOnly: contentSession.isSessionReadOnly,
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
  @Binding var showInspector: Bool

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      RefreshToolbarButton(isRefreshing: toolbarUI.isRefreshing) {
        Task { await store.refresh() }
      }
      .help("Refresh sessions")
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItem(placement: .primaryAction) {
      Button {
        showInspector.toggle()
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
