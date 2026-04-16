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

// MARK: - Content status backdrop

private enum ContentStatusBackdropLayout {
  static let gradientRadius: CGFloat = 380
  // Navigation buttons (back/forward) + spacing to title
  static let titleLeadingPadding: CGFloat = 75
}

struct ContentStatusBackdrop: View {
  let status: SessionStatus
  let isStale: Bool
  let titleLeadingEdge: CGFloat

  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var color: Color {
    isStale ? HarnessMonitorTheme.ink.opacity(0.55) : statusColor(for: status)
  }

  private var tintOpacity: Double {
    colorSchemeContrast == .increased ? 0.28 : 0.22
  }

  var body: some View {
    let radius = ContentStatusBackdropLayout.gradientRadius
    Circle()
      .fill(
        RadialGradient(
          colors: [
            color.opacity(tintOpacity),
            color.opacity(tintOpacity * 0.5),
            .clear,
          ],
          center: .center,
          startRadius: 0,
          endRadius: radius
        )
      )
      .frame(width: radius * 2, height: radius * 2)
      .offset(
        x: titleLeadingEdge + ContentStatusBackdropLayout.titleLeadingPadding - radius,
        y: -radius
      )
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

enum ContentInspectorVisibilitySource {
  case persistedPreference
  case explicitUserPreference
  case contextualAutoOpen
  case framework
}

struct ContentInspectorVisibilityChange: Equatable {
  let nextPresentation: Bool
  let persistedPreference: Bool?
  let shouldSuppressLayoutGeometry: Bool
}

enum ContentInspectorVisibilityPolicy {
  static func resolve(
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

struct ContentToolbarAccessibilityMarker: View {
  let toolbarUI: HarnessMonitorStore.ContentToolbarSlice

  var body: some View {
    AccessibilityTextMarker(
      identifier: HarnessMonitorAccessibility.toolbarCenterpieceState,
      text: toolbarUI.toolbarCenterpieceModel.accessibilityValue
    )
  }
}

struct ContentCornerOverlayModifier<CornerContent: View>: ViewModifier {
  let isPresented: Bool
  let cornerAnimationContent: CornerContent

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
            presentationDelay: nil
          )
        ) {
          cornerAnimationContent
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
  let showInspector: Bool
  let setInspectorVisibility: (Bool, ContentInspectorVisibilitySource) -> Void
  let toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration
  let onDetailColumnWidthChange: (CGFloat) -> Void

  private var navigationTitleText: String {
    contentSessionDetail.presentedSessionDetail != nil ? "Session Cockpit" : "Dashboard"
  }

  private var navigationSubtitleText: String? {
    contentSessionDetail.presentedSessionDetail?.session.status.title.uppercased()
  }

  var body: some View {
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
