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

public struct ContentDetailColumn: View {
  public let store: HarnessMonitorStore
  public let keyWindowObserver: KeyWindowObserver?
  public let toast: ToastSlice
  public let selection: HarnessMonitorStore.SelectionSlice
  public let contentChrome: HarnessMonitorStore.ContentChromeSlice
  public let contentSession: HarnessMonitorStore.ContentSessionSlice
  public let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice
  public let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  public let primaryContentFocusScope: Namespace.ID?
  public let primaryContentPagingResponderRequest: Int
  public let primaryContentFocusTarget: SessionContentPrimaryFocusTarget
  public let toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration

  public init(
    store: HarnessMonitorStore,
    keyWindowObserver: KeyWindowObserver? = nil,
    toast: ToastSlice,
    selection: HarnessMonitorStore.SelectionSlice,
    contentChrome: HarnessMonitorStore.ContentChromeSlice,
    contentSession: HarnessMonitorStore.ContentSessionSlice,
    contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice,
    primaryContentFocusScope: Namespace.ID? = nil,
    primaryContentPagingResponderRequest: Int = 0,
    primaryContentFocusTarget: SessionContentPrimaryFocusTarget,
    toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration
  ) {
    self.store = store
    self.keyWindowObserver = keyWindowObserver
    self.toast = toast
    self.selection = selection
    self.contentChrome = contentChrome
    self.contentSession = contentSession
    self.contentSessionDetail = contentSessionDetail
    self.dashboardUI = dashboardUI
    self.primaryContentFocusScope = primaryContentFocusScope
    self.primaryContentPagingResponderRequest = primaryContentPagingResponderRequest
    self.primaryContentFocusTarget = primaryContentFocusTarget
    self.toolbarGlassReproConfiguration = toolbarGlassReproConfiguration
  }

  private var navigationTitleText: String {
    contentSessionDetail.presentedSessionDetail != nil ? "Session Cockpit" : "Dashboard"
  }

  private var navigationSubtitleText: String? {
    contentSessionDetail.presentedSessionDetail?.session.status.title.uppercased()
  }

  private var contentToolbarModel: ContentWindowToolbarModel {
    ContentWindowToolbarModel(
      canNavigateBack: false,
      canNavigateForward: false,
      canCreateTask: false,
      isRefreshing: store.contentUI.toolbar.isRefreshing,
      sleepPreventionEnabled: store.contentUI.toolbar.sleepPreventionEnabled,
      mcpStatus: store.contentUI.toolbar.mcpStatus
    )
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
          store: store,
          contentChrome: contentChrome,
          keyWindowObserver: keyWindowObserver,
          windowID: HarnessMonitorWindowID.main,
          persistenceError: contentChrome.persistenceError,
          sessionDataAvailability: contentChrome.sessionDataAvailability,
          mcpStatus: contentChrome.mcpStatus,
          arbitrationTasks: contentSessionDetail.arbitrationBannerTasks
        ) {
          sessionContent
        }
      }
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
        model: contentToolbarModel
      )
    }
    .navigationTitle(navigationTitleText)
    .navigationSubtitle(navigationSubtitleText ?? "")
  }

  private var sessionContent: some View {
    SessionContentContainer(
      store: store,
      dashboardUI: dashboardUI,
      primaryContentFocusScope: primaryContentFocusScope,
      primaryContentPagingResponderRequest: primaryContentPagingResponderRequest,
      primaryContentFocusTarget: primaryContentFocusTarget,
      state: SessionContentState(
        detail: contentSessionDetail.presentedSessionDetail,
        summary: contentSession.selectedSessionSummary,
        timeline: contentSessionDetail.presentedTimeline,
        timelineWindow: contentSessionDetail.presentedTimelineWindow,
        tuiStatusByAgent: contentSessionDetail.tuiStatusByAgent,
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
      return .ignored
    }
  }
}
