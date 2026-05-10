import HarnessMonitorKit
import SwiftUI

enum SessionTimelineViewStyle {
  case cockpitSection
  case routePage
}

struct MonitorTimelineSection: View {
  let host: MonitorTimelineHost
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let decisions: [Decision]
  let isTimelineLoading: Bool
  let store: HarnessMonitorStore

  var body: some View {
    ViewBodySignposter.measure("MonitorTimelineSection") {
      SessionTimelineView(
        style: .cockpitSection,
        host: host,
        timeline: timeline,
        timelineWindow: timelineWindow,
        decisions: decisions,
        isTimelineLoading: isTimelineLoading,
        store: store
      )
    }
  }
}

struct SessionTimelinePresentationInput: Equatable {
  let sessionID: String
  let timelineCount: Int
  let firstTimelineEntryID: String?
  let firstTimelineRecordedAt: String?
  let lastTimelineEntryID: String?
  let lastTimelineRecordedAt: String?
  let timelineWindowRevision: Int64?
  let timelineWindowStart: Int?
  let timelineWindowEnd: Int?
  let timelineWindowHasOlder: Bool
  let timelineWindowHasNewer: Bool
  let decisionCount: Int
  let firstDecisionID: String?
  let lastDecisionID: String?
  let signalCount: Int
  let isTimelineLoading: Bool
  let filterSignature: String
  let reduceMotion: Bool
  let textSizeIndex: Int
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  static var empty: Self {
    Self(
      sessionID: "",
      timelineCount: 0,
      firstTimelineEntryID: nil,
      firstTimelineRecordedAt: nil,
      lastTimelineEntryID: nil,
      lastTimelineRecordedAt: nil,
      timelineWindowRevision: nil,
      timelineWindowStart: nil,
      timelineWindowEnd: nil,
      timelineWindowHasOlder: false,
      timelineWindowHasNewer: false,
      decisionCount: 0,
      firstDecisionID: nil,
      lastDecisionID: nil,
      signalCount: 0,
      isTimelineLoading: false,
      filterSignature: "",
      reduceMotion: false,
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      dateTimeConfiguration: .default
    )
  }
}

struct SessionTimelineFilterHydrationInput: Equatable {
  let sessionID: String
  let appStateRawValue: String
  let sceneRegistryRawValue: String
}

struct SessionTimelineFilterPersistenceSnapshot: Equatable, Sendable {
  let appStateRawValue: String
  let sceneRegistryRawValue: String
}

enum SessionTimelineFilterPersistenceResolver {
  static func hydrate(
    mode: SessionTimelineFilterPersistenceMode,
    input: SessionTimelineFilterHydrationInput
  ) -> SessionTimelineFilterState {
    switch mode {
    case .ephemeral:
      .init()
    case .application:
      SessionTimelineFilterState.decode(from: input.appStateRawValue) ?? .init()
    case .sessionWindow:
      SessionTimelineStoredFilterRegistry
        .decode(from: input.sceneRegistryRawValue)
        .state(for: input.sessionID) ?? .init()
    }
  }

  static func persist(
    mode: SessionTimelineFilterPersistenceMode,
    state: SessionTimelineFilterState,
    sessionID: String,
    appStateRawValue: String,
    sceneRegistryRawValue: String
  ) -> SessionTimelineFilterPersistenceSnapshot {
    switch mode {
    case .ephemeral:
      return SessionTimelineFilterPersistenceSnapshot(
        appStateRawValue: appStateRawValue,
        sceneRegistryRawValue: sceneRegistryRawValue
      )
    case .application:
      return SessionTimelineFilterPersistenceSnapshot(
        appStateRawValue: state.encodedString() ?? "",
        sceneRegistryRawValue: sceneRegistryRawValue
      )
    case .sessionWindow:
      var registry = SessionTimelineStoredFilterRegistry.decode(from: sceneRegistryRawValue)
      registry.set(state, for: sessionID)
      return SessionTimelineFilterPersistenceSnapshot(
        appStateRawValue: appStateRawValue,
        sceneRegistryRawValue: registry.encodedString() ?? ""
      )
    }
  }
}

struct SessionTimelineContentIdentity: Hashable {
  let sessionID: String
}

enum SessionTimelinePresentationRetention {
  static func shouldRetainPreviousPresentation(
    previousPresentation: SessionTimelineSectionPresentation,
    previousInput: SessionTimelinePresentationInput,
    nextPresentation: SessionTimelineSectionPresentation,
    nextInput: SessionTimelinePresentationInput
  ) -> Bool {
    guard previousInput.sessionID == nextInput.sessionID else {
      return false
    }
    guard !previousPresentation.rows.isEmpty, nextPresentation.rows.isEmpty else {
      return false
    }
    return nextInput.isTimelineLoading || nextPresentation.showsEmptyState
  }

  static func resolved(
    previousPresentation: SessionTimelineSectionPresentation,
    previousInput: SessionTimelinePresentationInput,
    nextPresentation: SessionTimelineSectionPresentation,
    nextInput: SessionTimelinePresentationInput
  ) -> SessionTimelineSectionPresentation {
    if shouldRetainPreviousPresentation(
      previousPresentation: previousPresentation,
      previousInput: previousInput,
      nextPresentation: nextPresentation,
      nextInput: nextInput
    ) {
      return previousPresentation
    }
    return nextPresentation
  }
}

enum SessionTimelinePlaceholderShimmer {
  static let cycleDuration: TimeInterval = 1.8
  static let restingPhase: CGFloat = -0.6

  static func shouldAnimate(reduceMotion: Bool, placeholderCount: Int) -> Bool {
    !reduceMotion && placeholderCount > 0
  }

  static func phase(at date: Date = Date()) -> CGFloat {
    let elapsedInCycle = date.timeIntervalSinceReferenceDate
      .truncatingRemainder(dividingBy: cycleDuration)
    let cycleProgress = elapsedInCycle / cycleDuration
    return restingPhase + (CGFloat(cycleProgress) * 2.4)
  }
}

extension SessionTimelineView {
  var contentIdentity: SessionTimelineContentIdentity {
    SessionTimelineContentIdentity(sessionID: sessionID)
  }

  func loadOlderTimelineChunk(limit: Int) async {
    await store.appendSelectedTimelineOlderChunk(limit: limit)
  }

  func loadWindow(_ request: TimelineWindowRequest) async {
    await store.loadSelectedTimelineWindow(request: request)
  }

  var actionHandler: any DecisionActionHandler {
    store.supervisorDecisionActionHandler()
  }
}

extension View {
  func timelineLifecycle(
    for presentation: SessionTimelineSectionPresentation,
    host: SessionTimelineView
  ) -> some View {
    onAppear {
      host.deferOffViewUpdate {
        host.reconcileTimelineAnchor(with: presentation.scrollNodeIDs)
      }
      host.requestLatestWindowIfNeeded(presentation)
    }
    .onChange(of: host.sessionID) { _, _ in
      host.deferOffViewUpdate {
        host.timelineViewport.clear()
        host.currentTimelineScrollCommand = nil
        host.currentPendingNavigation = nil
      }
      host.requestLatestWindow()
    }
    .onChange(of: presentation.scrollNodeIDs) { _, ids in
      guard !ids.isEmpty else { return }
      host.deferOffViewUpdate {
        host.reconcileTimelineAnchor(with: ids)
        host.completePendingNavigationIfNeeded(presentation)
      }
    }
  }
}
