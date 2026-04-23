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

public enum ContentInspectorInitialPresentation {
  private static let storageKey = "showInspector"

  public static func resolve(defaults: UserDefaults = .standard) -> Bool {
    guard defaults.object(forKey: storageKey) != nil else {
      return false
    }
    return defaults.bool(forKey: storageKey)
  }
}

public struct ContentInspectorVisibilityChange: Equatable {
  public let nextPresentation: Bool
  public let persistedPreference: Bool?
}

public enum ContentInspectorVisibilityPolicy {
  public static func resolve(
    currentPresentation: Bool,
    currentPersistedPreference: Bool,
    nextPresentation: Bool,
    source: ContentInspectorVisibilitySource
  ) -> ContentInspectorVisibilityChange? {
    let shouldPersistPreference: Bool

    switch source {
    case .persistedPreference:
      shouldPersistPreference = false
    case .explicitUserPreference:
      shouldPersistPreference = currentPersistedPreference != nextPresentation
    case .contextualAutoOpen:
      shouldPersistPreference = false
    case .framework:
      shouldPersistPreference = false
    }

    guard currentPresentation != nextPresentation || shouldPersistPreference else {
      return nil
    }

    return ContentInspectorVisibilityChange(
      nextPresentation: nextPresentation,
      persistedPreference: shouldPersistPreference ? nextPresentation : nil
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
  public let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  public let showInspector: Bool
  public let setInspectorVisibility: (Bool, ContentInspectorVisibilitySource) -> Void
  public let toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration

  public init(
    store: HarnessMonitorStore,
    toast: ToastSlice,
    selection: HarnessMonitorStore.SelectionSlice,
    contentChrome: HarnessMonitorStore.ContentChromeSlice,
    contentSession: HarnessMonitorStore.ContentSessionSlice,
    contentSessionDetail: HarnessMonitorStore.ContentSessionDetailSlice,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice,
    showInspector: Bool,
    setInspectorVisibility: @escaping (Bool, ContentInspectorVisibilitySource) -> Void,
    toolbarGlassReproConfiguration: ToolbarGlassReproConfiguration
  ) {
    self.store = store
    self.toast = toast
    self.selection = selection
    self.contentChrome = contentChrome
    self.contentSession = contentSession
    self.contentSessionDetail = contentSessionDetail
    self.dashboardUI = dashboardUI
    self.showInspector = showInspector
    self.setInspectorVisibility = setInspectorVisibility
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
      sleepPreventionEnabled: store.contentUI.toolbar.sleepPreventionEnabled,
      showInspector: showInspector
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
          sessionDataAvailability: contentChrome.sessionDataAvailability
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
        model: contentToolbarModel,
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
      if contentSessionDetail.presentedSessionDetail != nil {
        store.inspectorSelection = .none
        return .handled
      }
      return .ignored
    }
  }
}
