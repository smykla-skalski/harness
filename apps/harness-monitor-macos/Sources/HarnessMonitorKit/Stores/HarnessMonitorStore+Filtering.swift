import Foundation
import Observation

extension HarnessMonitorStore {
  @MainActor
  @Observable
  public final class SessionIndexSlice {
    public enum Change {
      case snapshot
      case projection
      case summaryProjection(sessionID: String)
      case summaryMetadata(sessionID: String)
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    public let catalog: SessionCatalogSlice
    public let controls: SessionControlsSlice
    public let projection: SessionProjectionSlice
    public let searchResults: SessionSearchResultsSlice

    @ObservationIgnored var suppressRefresh = false
    @ObservationIgnored var sessionRecordsByID: [String: SessionRecord] = [:]
    @ObservationIgnored var sessionIndicesByID: [String: Int] = [:]
    @ObservationIgnored var projectCatalogs: [ProjectCatalog] = []
    @ObservationIgnored var orderedSessionIDsBySortOrder: [SessionSortOrder: [String]] = [:]
    @ObservationIgnored var queryTokens: [String] = []
    @ObservationIgnored var searchRebuildTask: Task<Void, Never>?
    @ObservationIgnored var projectionComputationTask: Task<Void, Never>?
    @ObservationIgnored var projectionGeneration: UInt64 = 0
    @ObservationIgnored var debugCatalogRebuildCount = 0
    @ObservationIgnored var debugProjectionRebuildCount = 0
    @ObservationIgnored var debugProjectionDelayNanoseconds: UInt64 = 0

    static let searchRebuildDebounceNanoseconds: UInt64 = 150_000_000

    public var projects: [ProjectSummary] {
      get { catalog.projects }
      set {
        refreshCatalogIfNeeded(
          newValue != catalog.projects, projects: newValue, sessions: catalog.sessions)
      }
    }

    public var sessions: [SessionSummary] {
      get { catalog.sessions }
      set {
        refreshCatalogIfNeeded(
          newValue != catalog.sessions, projects: catalog.projects, sessions: newValue)
      }
    }

    public var searchText: String {
      get { controls.searchText }
      set { updateSearchText(newValue) }
    }

    public var sessionFilter: SessionFilter {
      get { controls.sessionFilter }
      set { updateSessionFilter(newValue) }
    }

    public var sessionFocusFilter: SessionFocusFilter {
      get { controls.sessionFocusFilter }
      set { updateSessionFocusFilter(newValue) }
    }

    public var sessionSortOrder: SessionSortOrder {
      get { controls.sessionSortOrder }
      set { updateSessionSortOrder(newValue) }
    }

    public var groupedSessions: [SessionGroup] {
      guard queryTokens.isEmpty else {
        return buildGroupedSessions(
          visibleSessionIDSet: Set(searchResults.visibleSessionIDs)
        )
      }
      return projection.groupedSessions
    }

    public var filteredSessionCount: Int {
      searchResults.filteredSessionCount
    }

    public var totalSessionCount: Int {
      catalog.totalSessionCount
    }

    public var totalOpenWorkCount: Int {
      catalog.totalOpenWorkCount
    }

    public var totalBlockedCount: Int {
      catalog.totalBlockedCount
    }

    public var visibleSessionIDs: [String] {
      searchResults.visibleSessionIDs
    }

    public var recentSessions: [SessionSummary] {
      catalog.recentSessions
    }

    public init() {
      self.catalog = SessionCatalogSlice()
      self.controls = SessionControlsSlice()
      self.projection = SessionProjectionSlice()
      self.searchResults = SessionSearchResultsSlice()
      rebuildProjection(change: .projection)
    }

    @discardableResult
    public func replaceSnapshot(
      projects: [ProjectSummary],
      sessions: [SessionSummary]
    ) -> Bool {
      guard catalog.projects != projects || catalog.sessions != sessions else {
        return false
      }

      cancelPendingSearchRebuild()
      suppressRefresh = true
      catalog.projects = projects
      catalog.sessions = sessions
      suppressRefresh = false
      rebuildCatalogAndProjection(change: .snapshot)
      return true
    }

    @discardableResult
    public func applySessionSummary(_ summary: SessionSummary) -> Bool {
      if let index = sessionIndicesByID[summary.sessionId] {
        let existing = catalog.sessions[index]
        guard existing != summary else {
          return false
        }

        var updated = catalog.sessions
        updated[index] = summary
        suppressRefresh = true
        catalog.sessions = updated
        suppressRefresh = false

        switch summaryChangeImpact(from: existing, to: summary) {
        case .catalog:
          cancelPendingSearchRebuild()
          rebuildCatalogAndProjection(change: .snapshot)
        case .projection:
          cancelPendingSearchRebuild()
          patchCatalog(existingSummary: existing, updatedSummary: summary)
          rebuildProjection(change: .summaryProjection(sessionID: summary.sessionId))
        case .summaryOnly:
          patchCatalog(existingSummary: existing, updatedSummary: summary)
          onChanged?(.summaryMetadata(sessionID: summary.sessionId))
        }
        return true
      }

      var updated = catalog.sessions
      updated.append(summary)
      suppressRefresh = true
      catalog.sessions = updated
      suppressRefresh = false
      cancelPendingSearchRebuild()
      rebuildCatalogAndProjection(change: .snapshot)
      return true
    }

    public func flushPendingSearchRebuild() {
      guard searchRebuildTask != nil || projectionComputationTask != nil else {
        return
      }
      cancelPendingSearchRebuild()
      rebuildProjection(change: .projection)
    }

    public func sessionSummary(for sessionID: String?) -> SessionSummary? {
      guard let sessionID else {
        return nil
      }
      return catalog.sessionSummary(for: sessionID)
    }

  }
}
