import Foundation

public enum OpenAnythingDomain: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case actions
  case windows
  case settings
  case sessions
  case taskBoard
  case decisions
  case dependencies
  case loadedSession

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .actions: "Actions"
    case .windows: "Windows"
    case .settings: "Settings"
    case .sessions: "Sessions"
    case .taskBoard: "Task Board"
    case .decisions: "Decisions"
    case .dependencies: "Dependencies"
    case .loadedSession: "Loaded Session"
    }
  }

  public var systemImage: String {
    switch self {
    case .actions: "bolt"
    case .windows: "macwindow"
    case .settings: "gearshape"
    case .sessions: "rectangle.stack"
    case .taskBoard: "checklist"
    case .decisions: "checkmark.diamond"
    case .dependencies: "shippingbox"
    case .loadedSession: "sidebar.leading"
    }
  }
}

public enum OpenAnythingAction: String, Codable, CaseIterable, Hashable, Sendable {
  case newSession
  case newTask
  case attachExternalSession
  case refresh
  case settings
  case policyCanvasLab
}

public enum OpenAnythingWindowTarget: String, Codable, CaseIterable, Hashable, Sendable {
  case dashboard
  case settings
  case policyCanvasLab
}

public enum OpenAnythingDashboardRoute: String, Codable, CaseIterable, Hashable, Sendable {
  case taskBoard
  case policyCanvas
  case notifications
  case dependencies

  public var title: String {
    switch self {
    case .taskBoard: "Board"
    case .policyCanvas: "Policy"
    case .notifications: "Notifications"
    case .dependencies: "Dependencies"
    }
  }

  public var systemImage: String {
    switch self {
    case .taskBoard: "square.grid.2x2"
    case .policyCanvas: "point.3.connected.trianglepath.dotted"
    case .notifications: "bell.badge"
    case .dependencies: "shippingbox.circle"
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
  case dependency(pullRequestID: String)
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

  public init(
    id: String,
    domain: OpenAnythingDomain,
    target: OpenAnythingTarget,
    title: String,
    subtitle: String? = nil,
    trailing: String? = nil,
    systemImage: String? = nil,
    searchBodyParts: [String?] = []
  ) {
    self.id = id
    self.domain = domain
    self.target = target
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
    self.systemImage = systemImage ?? domain.systemImage
    searchBody = searchBodyParts.compactMap(Self.nonEmpty).joined(separator: " ")
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
  public let domain: OpenAnythingDomain
  public let hits: [OpenAnythingHit]
  public var id: OpenAnythingDomain { domain }
}

public struct OpenAnythingResults: Hashable, Sendable {
  public let query: String
  public let sections: [OpenAnythingSection]

  public static let empty = Self(query: "", sections: [])

  public var allHits: [OpenAnythingHit] {
    sections.flatMap(\.hits)
  }

  public var isEmpty: Bool {
    sections.isEmpty
  }
}
