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

struct SessionTimelineLoading {
  let loadWindow: @MainActor (TimelineWindowRequest, Int?) async -> Void
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
  var filterHydrationInput: SessionTimelineFilterHydrationInput {
    SessionTimelineFilterHydrationInput(
      sessionID: sessionID,
      appStateRawValue: appStoredFilterStateRawValue,
      sceneRegistryRawValue: sceneStoredFilterRegistryRawValue
    )
  }

  func hydrateFilters(for input: SessionTimelineFilterHydrationInput) {
    let hydrated = SessionTimelineFilterPersistenceResolver.hydrate(
      mode: filterPersistenceMode,
      input: input
    )
    if hydrated != filterState {
      filterState = hydrated
    }
  }

  func applyPerfScenarioFiltersIfNeeded() {
    guard HarnessMonitorUITestEnvironment.perfScenarioBaseValue == "timeline-filter-form" else {
      return
    }
    var seeded = SessionTimelineFilterState()
    seeded.query = "worker"
    seeded.toggleSignalPreset()
    seeded.toggleAgent(PreviewFixtures.agents[1].agentId)
    seeded.toggleTask(PreviewFixtures.tasks[0].taskId)
    seeded.toggleSemanticProperty(.toolCall)
    guard filterState != seeded else { return }
    filterState = seeded
  }

  func persistFilters(_ state: SessionTimelineFilterState) {
    let snapshot = SessionTimelineFilterPersistenceResolver.persist(
      mode: filterPersistenceMode,
      state: state,
      sessionID: sessionID,
      appStateRawValue: appStoredFilterStateRawValue,
      sceneRegistryRawValue: sceneStoredFilterRegistryRawValue
    )
    if snapshot.appStateRawValue != appStoredFilterStateRawValue {
      appStoredFilterStateRawValue = snapshot.appStateRawValue
    }
    if snapshot.sceneRegistryRawValue != sceneStoredFilterRegistryRawValue {
      sceneStoredFilterRegistryRawValue = snapshot.sceneRegistryRawValue
    }
  }

  static let initialPageLimit = 10

  func requestLatestWindowIfNeeded(_ presentation: SessionTimelineSectionPresentation) {
    if timeline.isEmpty {
      requestLatestWindow()
      return
    }
    guard timelineLoading != nil, !didInitialFreshFetch else { return }
    didInitialFreshFetch = true
    HarnessMonitorLogger.timelinePaging.info(
      "section.refresh forcing latest=\(Self.initialPageLimit, privacy: .public) on first appear"
    )
    requestLatestWindow()
  }

  func requestLatestWindow() {
    let request = TimelineWindowRequest.latest(limit: Self.initialPageLimit)
    if let timelineLoading {
      Task { await timelineLoading.loadWindow(request, nil) }
      return
    }
    Task { await store.loadSelectedTimelineWindow(request: request, retainedLimit: nil) }
  }
}
