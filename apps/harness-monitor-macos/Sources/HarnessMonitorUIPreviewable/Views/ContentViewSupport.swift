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
  public let toast: ToastSlice
  public let selection: HarnessMonitorStore.SelectionSlice
  public let contentChrome: HarnessMonitorStore.ContentChromeSlice
  public let contentSession: HarnessMonitorStore.ContentSessionSlice
  public let contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice
  public let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  public let toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration

  public init(
    store: HarnessMonitorStore,
    toast: ToastSlice,
    selection: HarnessMonitorStore.SelectionSlice,
    contentChrome: HarnessMonitorStore.ContentChromeSlice,
    contentSession: HarnessMonitorStore.ContentSessionSlice,
    contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice,
    toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration
  ) {
    self.store = store
    self.toast = toast
    self.selection = selection
    self.contentChrome = contentChrome
    self.contentSession = contentSession
    self.contentSessionDetail = contentSessionDetail
    self.dashboardUI = dashboardUI
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
      canStartNewSession: false,
      isRefreshing: store.contentUI.toolbar.isRefreshing,
      sleepPreventionEnabled: store.contentUI.toolbar.sleepPreventionEnabled
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
          persistenceError: contentChrome.persistenceError,
          sessionDataAvailability: contentChrome.sessionDataAvailability,
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
