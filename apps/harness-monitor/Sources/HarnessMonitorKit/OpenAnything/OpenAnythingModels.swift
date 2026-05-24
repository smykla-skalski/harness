import Foundation
import SwiftUI

public enum OpenAnythingDomain: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case actions
  case windows
  case settings
  case sessions
  case taskBoard
  case decisions
  case reviews
  case loadedSession

  public var id: String { rawValue }

  public static let displayOrder: [Self] = [
    .actions,
    .windows,
    .settings,
    .sessions,
    .taskBoard,
    .decisions,
    .reviews,
    .loadedSession,
  ]

  /// Plain-text section label. Kept as `String` because the palette view applies
  /// `.uppercased()` before rendering. Use ``labelKey`` for a localized variant
  /// suitable for direct SwiftUI consumers.
  public var label: String {
    switch self {
    case .actions: "Actions"
    case .windows: "Windows"
    case .settings: "Settings"
    case .sessions: "Sessions"
    case .taskBoard: "Task Board"
    case .decisions: "Decisions"
    case .reviews: "Reviews"
    case .loadedSession: "Loaded Session"
    }
  }

  /// Localization-friendly accessor for ``label`` at the type boundary. Future
  /// view rewrites should consume this when handing copy to SwiftUI directly.
  public var labelKey: LocalizedStringKey {
    LocalizedStringKey(label)
  }

  public var systemImage: String {
    switch self {
    case .actions: "bolt"
    case .windows: "macwindow"
    case .settings: "gearshape"
    case .sessions: "rectangle.stack"
    case .taskBoard: "checklist"
    case .decisions: "checkmark.diamond"
    case .reviews: "shippingbox"
    case .loadedSession: "sidebar.leading"
    }
  }
}

public enum OpenAnythingAction: String, Codable, CaseIterable, Hashable, Sendable {
  case newSession
  case newTask
  case attachExternalSession
  case openDashboard
  case openTaskBoard
  case openReviews
  case openNotifications
  case openPolicyCanvas
  case openDiagnostics
  case refreshDiagnostics
  case reconnectDaemon
  case copyDiagnostics
  case refresh
  case settings
  case openMCPSettings
  case openDatabaseSettings
  case policyCanvasLab

  /// Plain-text title for the action. Stays `String` because the corpus
  /// builder writes it into `OpenAnythingRecord.title` which is `String` for
  /// now. Localized variant exposed via ``titleKey``.
  public var title: String {
    switch self {
    case .newSession: "New Session"
    case .newTask: "New Task"
    case .attachExternalSession: "Attach External Session"
    case .openDashboard: "Open Dashboard"
    case .openTaskBoard: "Open Board"
    case .openReviews: "Open Reviews"
    case .openNotifications: "Open Notifications"
    case .openPolicyCanvas: "Open Policy"
    case .openDiagnostics: "Open Diagnostics"
    case .refreshDiagnostics: "Refresh Diagnostics"
    case .reconnectDaemon: "Reconnect Daemon"
    case .copyDiagnostics: "Copy Diagnostics"
    case .refresh: "Refresh"
    case .settings: "Settings"
    case .openMCPSettings: "Open MCP Settings"
    case .openDatabaseSettings: "Open Database Settings"
    case .policyCanvasLab: "Policy Canvas Lab"
    }
  }

  /// Localization-friendly accessor for ``title`` at the type boundary.
  public var titleKey: LocalizedStringKey {
    LocalizedStringKey(title)
  }

  public var subtitle: String {
    switch self {
    case .newSession, .newTask, .attachExternalSession:
      "Create"
    case .openDashboard, .openTaskBoard, .openReviews, .openNotifications,
      .openPolicyCanvas, .openDiagnostics:
      "Navigate"
    case .refresh:
      "Reload Monitor data"
    case .refreshDiagnostics:
      "Reload daemon diagnostics"
    case .reconnectDaemon:
      "Restart the Monitor connection"
    case .copyDiagnostics:
      "Copy Monitor state"
    case .settings:
      "Open Settings"
    case .openMCPSettings:
      "Open Settings > MCP"
    case .openDatabaseSettings:
      "Open Settings > Database"
    case .policyCanvasLab:
      "Open experimental window"
    }
  }

  /// Localization-friendly accessor for ``subtitle`` at the type boundary.
  public var subtitleKey: LocalizedStringKey {
    LocalizedStringKey(subtitle)
  }

  public var systemImage: String {
    switch self {
    case .newSession: "plus.rectangle.on.folder"
    case .newTask: "checklist"
    case .attachExternalSession: "link.badge.plus"
    case .openDashboard: "square.grid.2x2"
    case .openTaskBoard: "list.bullet.rectangle"
    case .openReviews: "shippingbox.circle"
    case .openNotifications: "bell.badge"
    case .openPolicyCanvas: "point.3.connected.trianglepath.dotted"
    case .openDiagnostics: "stethoscope"
    case .refresh: "arrow.clockwise"
    case .refreshDiagnostics: "stethoscope.circle"
    case .reconnectDaemon: "arrow.triangle.2.circlepath"
    case .copyDiagnostics: "doc.on.clipboard"
    case .settings: "gearshape"
    case .openMCPSettings: "point.3.connected.trianglepath.dotted"
    case .openDatabaseSettings: "internaldrive"
    case .policyCanvasLab: "point.3.connected.trianglepath.dotted"
    }
  }

  public var searchAliases: String {
    switch self {
    case .openTaskBoard:
      "task board board operations dispatch"
    case .openReviews:
      "review pull requests prs renovate checks merge approvals"
    case .openDiagnostics, .refreshDiagnostics, .copyDiagnostics:
      "diagnostics health daemon cache provenance freshness mcp"
    case .reconnectDaemon:
      "reconnect daemon offline stale connection"
    case .openMCPSettings:
      "mcp accessibility registry host"
    case .openDatabaseSettings:
      "database cache sqlite persistence"
    case .openNotifications:
      "alerts notification history"
    case .openPolicyCanvas, .policyCanvasLab:
      "policy canvas graph"
    case .newSession, .newTask, .attachExternalSession, .openDashboard, .refresh, .settings:
      ""
    }
  }
}

public enum OpenAnythingWindowTarget: String, Codable, CaseIterable, Hashable, Sendable {
  case dashboard
  case settings
  case policyCanvasLab

  public var title: String {
    switch self {
    case .dashboard: "Dashboard"
    case .settings: "Settings"
    case .policyCanvasLab: "Policy Canvas Lab"
    }
  }

  public var systemImage: String {
    switch self {
    case .dashboard: "square.grid.2x2"
    case .settings: "gearshape"
    case .policyCanvasLab: "point.3.connected.trianglepath.dotted"
    }
  }
}

public enum OpenAnythingDashboardRoute: String, Codable, CaseIterable, Hashable, Sendable {
  case taskBoard
  case policyCanvas
  case notifications
  case diagnostics
  case reviews

  public var title: String {
    switch self {
    case .taskBoard: "Board"
    case .policyCanvas: "Policy"
    case .notifications: "Notifications"
    case .diagnostics: "Diagnostics"
    case .reviews: "Reviews"
    }
  }

  /// Localization-friendly accessor for ``title`` at the type boundary.
  public var titleKey: LocalizedStringKey {
    LocalizedStringKey(title)
  }

  public var systemImage: String {
    switch self {
    case .taskBoard: "square.grid.2x2"
    case .policyCanvas: "point.3.connected.trianglepath.dotted"
    case .notifications: "bell.badge"
    case .diagnostics: "stethoscope"
    case .reviews: "shippingbox.circle"
    }
  }
}

public enum OpenAnythingLoadedSessionTarget: Codable, Hashable, Sendable {
  case agent(sessionID: String, agentID: String)
  case task(sessionID: String, taskID: String)
  case timeline(sessionID: String, entryID: String)
}

public enum OpenAnythingTarget: Codable, Hashable, Sendable {
  case action(OpenAnythingAction)
  case window(OpenAnythingWindowTarget)
  case dashboardRoute(OpenAnythingDashboardRoute)
  case settingsSection(rawValue: String)
  case session(sessionID: String)
  case taskBoardItem(id: String, sessionID: String?, workItemID: String?)
  case decision(id: String, sessionID: String?)
  case review(pullRequestID: String)
  case loadedSession(OpenAnythingLoadedSessionTarget)
}

public struct OpenAnythingRecord: Identifiable, Hashable, Sendable {
  public let id: String
  public let domain: OpenAnythingDomain
  public let target: OpenAnythingTarget
  public let title: String
  public let subtitle: String?
  public let trailing: String?
  public let systemImage: String
  public let searchBody: String
  public let isSuggested: Bool

  public init(
    id: String,
    domain: OpenAnythingDomain,
    target: OpenAnythingTarget,
    title: String,
    subtitle: String? = nil,
    trailing: String? = nil,
    systemImage: String? = nil,
    isSuggested: Bool = false,
    searchBodyParts: [String?] = []
  ) {
    self.id = id
    self.domain = domain
    self.target = target
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
    self.systemImage = systemImage ?? domain.systemImage
    self.isSuggested = isSuggested
    searchBody = Self.joinSearchBody(searchBodyParts)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func joinSearchBody(_ parts: [String?]) -> String {
    var body = ""
    for part in parts {
      guard let trimmed = nonEmpty(part) else { continue }
      if !body.isEmpty {
        body.append(" ")
      }
      body.append(trimmed)
    }
    return body
  }
}

public struct OpenAnythingHit: Identifiable, Hashable, Sendable {
  public let record: OpenAnythingRecord
  public let highlights: SearchHighlights
  public let score: Int

  public var id: String { record.id }
  public var domain: OpenAnythingDomain { record.domain }
  public var target: OpenAnythingTarget { record.target }
}

public struct OpenAnythingSection: Identifiable, Hashable, Sendable {
  public let id: String
  public let domain: OpenAnythingDomain
  public let title: String
  public let systemImage: String
  public let totalCount: Int?
  public let hits: [OpenAnythingHit]

  public init(
    id: String? = nil,
    domain: OpenAnythingDomain,
    title: String? = nil,
    systemImage: String? = nil,
    totalCount: Int? = nil,
    hits: [OpenAnythingHit]
  ) {
    self.id = id ?? domain.rawValue
    self.domain = domain
    self.title = title ?? domain.label
    self.systemImage = systemImage ?? domain.systemImage
    self.totalCount = totalCount
    self.hits = hits
  }
}

public struct OpenAnythingResults: Hashable, Sendable {
  public let query: String
  public let sections: [OpenAnythingSection]
  /// Per-domain match counts before the per-section cap is applied. Lets
  /// section headers show "Show all (N)" with the real total without forcing
  /// the view to know about the limit.
  public let domainTotals: [OpenAnythingDomain: Int]

  public static let empty = Self(query: "", sections: [], domainTotals: [:])

  public init(
    query: String,
    sections: [OpenAnythingSection],
    domainTotals: [OpenAnythingDomain: Int] = [:]
  ) {
    self.query = query
    self.sections = sections
    self.domainTotals = domainTotals
  }

  public var allHits: [OpenAnythingHit] {
    sections.flatMap(\.hits)
  }

  public var isEmpty: Bool {
    sections.isEmpty
  }

  public func totalCount(for domain: OpenAnythingDomain) -> Int {
    domainTotals[domain]
      ?? sections.first(where: { $0.domain == domain })?.hits.count
      ?? 0
  }

  public func totalCount(for section: OpenAnythingSection) -> Int {
    section.totalCount ?? totalCount(for: section.domain)
  }
}
