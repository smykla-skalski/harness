import Foundation

public enum MobileNotificationCategory: String, Codable, CaseIterable, Identifiable, Sendable {
  case needsYou
  case criticalDecision
  case commandStatus
  case commandFailure
  case stationHealth

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .needsYou: String(localized: "Needs you", bundle: .module)
    case .criticalDecision: String(localized: "Critical decisions", bundle: .module)
    case .commandStatus: String(localized: "Command status", bundle: .module)
    case .commandFailure: String(localized: "Command failures", bundle: .module)
    case .stationHealth: String(localized: "Station health", bundle: .module)
    }
  }

  public var subtitle: String {
    switch self {
    case .needsYou:
      String(localized: "Reviews, blocked agents, and other waiting work", bundle: .module)
    case .criticalDecision:
      String(localized: "High-priority permission decisions", bundle: .module)
    case .commandStatus:
      String(localized: "Accepted, running, completed, and cancelled commands", bundle: .module)
    case .commandFailure:
      String(localized: "Failed or expired command receipts", bundle: .module)
    case .stationHealth:
      String(localized: "Stale or offline Mac relays", bundle: .module)
    }
  }
}

public enum MobileNotificationInterruption: String, Codable, Sendable {
  case passive
  case active
  case timeSensitive
}

public enum MobileNotificationDestination: String, Codable, Equatable, Sendable {
  case today
  case sessions
  case reviews
  case commands
  case settings
}

public struct MobileNotificationSettings: Codable, Equatable, Sendable {
  public static let userDefaultsKey = "io.harnessmonitor.mobile.notifications.settings.v1"

  public var enabledCategories: Set<MobileNotificationCategory>

  public init(enabledCategories: Set<MobileNotificationCategory> = Self.smartDefaultCategories) {
    self.enabledCategories = enabledCategories
  }

  public static var smartDefaults: Self {
    Self(enabledCategories: smartDefaultCategories)
  }

  public static var smartDefaultCategories: Set<MobileNotificationCategory> {
    Set(MobileNotificationCategory.allCases)
  }

  public func isEnabled(_ category: MobileNotificationCategory) -> Bool {
    enabledCategories.contains(category)
  }

  public mutating func setEnabled(_ enabled: Bool, for category: MobileNotificationCategory) {
    if enabled {
      enabledCategories.insert(category)
    } else {
      enabledCategories.remove(category)
    }
  }

  public static func load(
    from userDefaults: UserDefaults = .standard,
    key: String = userDefaultsKey
  ) -> Self {
    guard let data = userDefaults.data(forKey: key),
      let decoded = try? JSONDecoder().decode(Self.self, from: data)
    else {
      return .smartDefaults
    }
    return decoded
  }

  public func save(
    to userDefaults: UserDefaults = .standard,
    key: String = userDefaultsKey
  ) {
    guard let data = try? JSONEncoder().encode(self) else {
      return
    }
    userDefaults.set(data, forKey: key)
  }
}

public struct MobileNotificationRequest: Equatable, Identifiable, Sendable {
  public var id: String
  public var category: MobileNotificationCategory
  public var stationID: String
  public var title: String
  public var body: String
  public var interruption: MobileNotificationInterruption
  public var destination: MobileNotificationDestination
  public var createdAt: Date

  public init(
    id: String,
    category: MobileNotificationCategory,
    stationID: String,
    title: String,
    body: String,
    interruption: MobileNotificationInterruption,
    destination: MobileNotificationDestination = .today,
    createdAt: Date
  ) {
    self.id = id
    self.category = category
    self.stationID = stationID
    self.title = title
    self.body = body
    self.interruption = interruption
    self.destination = destination
    self.createdAt = createdAt
  }
}

public enum MobileNotificationPlanner {
  public static let maximumRequestsPerRefresh = 8

  public static func requests(
    previous: MobileMirrorSnapshot?,
    next: MobileMirrorSnapshot,
    settings: MobileNotificationSettings
  ) -> [MobileNotificationRequest] {
    var requests: [MobileNotificationRequest] = []
    requests.append(
      contentsOf: attentionRequests(previous: previous, next: next, settings: settings))
    requests.append(
      contentsOf: stationHealthRequests(previous: previous, next: next, settings: settings))
    requests.append(contentsOf: commandRequests(previous: previous, next: next, settings: settings))
    return
      Array(
        requests
          .sorted {
            if $0.interruption.rank != $1.interruption.rank {
              return $0.interruption.rank < $1.interruption.rank
            }
            return $0.createdAt > $1.createdAt
          }
          .prefix(maximumRequestsPerRefresh)
      )
  }

  private static func attentionRequests(
    previous: MobileMirrorSnapshot?,
    next: MobileMirrorSnapshot,
    settings: MobileNotificationSettings
  ) -> [MobileNotificationRequest] {
    let previousIDs = Set(previous?.sortedAttention.map(\.id) ?? [])
    return next.sortedAttention.compactMap { item in
      guard !previousIDs.contains(item.id) else {
        return nil
      }
      if item.kind == .acpDecision, item.severity == .critical {
        guard settings.isEnabled(.criticalDecision) else {
          return nil
        }
        return MobileNotificationRequest(
          id: "mobile.critical-decision.\(item.stationID).\(item.id)",
          category: .criticalDecision,
          stationID: item.stationID,
          title: item.title,
          body: item.subtitle,
          interruption: .timeSensitive,
          destination: .today,
          createdAt: item.updatedAt
        )
      }
      guard item.kind != .stationHealth,
        item.kind != .commandFailure,
        item.severity == .critical || item.severity == .warning || item.kind == .pullRequest,
        settings.isEnabled(.needsYou)
      else {
        return nil
      }
      return MobileNotificationRequest(
        id: "mobile.needs-you.\(item.stationID).\(item.id)",
        category: .needsYou,
        stationID: item.stationID,
        title: item.title,
        body: item.subtitle,
        interruption: item.severity == .critical ? .timeSensitive : .active,
        destination: destination(for: item),
        createdAt: item.updatedAt
      )
    }
  }

  private static func destination(
    for item: MobileAttentionItem
  ) -> MobileNotificationDestination {
    switch item.kind {
    case .pullRequest:
      return .reviews
    case .blockedAgent, .taskBoard:
      return .sessions
    case .commandFailure:
      return .commands
    case .acpDecision, .stationHealth:
      return .today
    }
  }

  private static func stationHealthRequests(
    previous: MobileMirrorSnapshot?,
    next: MobileMirrorSnapshot,
    settings: MobileNotificationSettings
  ) -> [MobileNotificationRequest] {
    guard settings.isEnabled(.stationHealth) else {
      return []
    }
    let previousStations = Dictionary(
      uniqueKeysWithValues: (previous?.stations ?? []).map { ($0.id, $0) })
    return next.stations.compactMap { station in
      guard station.state != .online else {
        return nil
      }
      let previousState = previousStations[station.id]?.state
      guard previousState == nil || previousState == .online || previousState != station.state
      else {
        return nil
      }
      let sessionCount = station.activeSessionCount
      return MobileNotificationRequest(
        id: "mobile.station-health.\(station.id).\(station.state.rawValue).\(next.revision)",
        category: .stationHealth,
        stationID: station.id,
        title: String(
          localized: "\(station.displayName) is \(station.state.title.lowercased())",
          bundle: .module),
        body: String(localized: "\(sessionCount) active sessions on this Mac", bundle: .module),
        interruption: station.state == .offline ? .timeSensitive : .active,
        destination: .today,
        createdAt: next.generatedAt
      )
    }
  }

  private static func commandRequests(
    previous: MobileMirrorSnapshot?,
    next: MobileMirrorSnapshot,
    settings: MobileNotificationSettings
  ) -> [MobileNotificationRequest] {
    let previousCommands = Dictionary(
      uniqueKeysWithValues: (previous?.commands ?? []).map { ($0.id, $0) })
    return next.commands.compactMap { command in
      let previousStatus = previousCommands[command.id]?.status
      guard previousStatus != command.status else {
        return nil
      }
      switch command.status {
      case .failed, .expired:
        guard settings.isEnabled(.commandFailure) else {
          return nil
        }
        return MobileNotificationRequest(
          id: "mobile.command-failure.\(command.id).\(command.status.rawValue)",
          category: .commandFailure,
          stationID: command.stationID,
          title: "\(command.title) \(command.status.title.lowercased())",
          body: command.receipt?.message ?? command.confirmationText,
          interruption: .timeSensitive,
          destination: .commands,
          createdAt: command.updatedAt
        )
      case .accepted, .running, .succeeded, .cancelled:
        guard settings.isEnabled(.commandStatus) else {
          return nil
        }
        return MobileNotificationRequest(
          id: "mobile.command-status.\(command.id).\(command.status.rawValue)",
          category: .commandStatus,
          stationID: command.stationID,
          title: "\(command.title) \(command.status.title.lowercased())",
          body: command.receipt?.message ?? command.confirmationText,
          interruption: .active,
          destination: .commands,
          createdAt: command.updatedAt
        )
      case .draft, .queued:
        return nil
      }
    }
  }
}

public struct MobileNotificationDeliveryHistory {
  public static let userDefaultsKey = "io.harnessmonitor.mobile.notifications.delivered.v1"

  private let userDefaults: UserDefaults
  private let key: String
  private let limit: Int

  public init(
    userDefaults: UserDefaults = .standard,
    key: String = userDefaultsKey,
    limit: Int = 512
  ) {
    self.userDefaults = userDefaults
    self.key = key
    self.limit = limit
  }

  public func unrecordedRequests(_ requests: [MobileNotificationRequest])
    -> [MobileNotificationRequest]
  {
    let deliveredIDs = loadDeliveredIDs()
    return requests.filter { request in
      !deliveredIDs.contains(request.id)
    }
  }

  public func recordDeliveredRequestIDs(_ requestIDs: some Sequence<String>) {
    var deliveredIDs = loadDeliveredIDArray()
    for requestID in requestIDs {
      deliveredIDs.removeAll { $0 == requestID }
      deliveredIDs.append(requestID)
    }
    saveDeliveredIDs(deliveredIDs)
  }

  public func reset() {
    userDefaults.removeObject(forKey: key)
  }

  private func loadDeliveredIDs() -> Set<String> {
    Set(loadDeliveredIDArray())
  }

  private func loadDeliveredIDArray() -> [String] {
    userDefaults.stringArray(forKey: key) ?? []
  }

  private func saveDeliveredIDs(_ ids: [String]) {
    userDefaults.set(Array(ids.suffix(limit)), forKey: key)
  }
}

extension MobileNotificationInterruption {
  fileprivate var rank: Int {
    switch self {
    case .timeSensitive: 0
    case .active: 1
    case .passive: 2
    }
  }
}
