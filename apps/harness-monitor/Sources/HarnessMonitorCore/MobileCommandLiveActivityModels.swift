import Foundation

#if canImport(ActivityKit) && os(iOS)
  import ActivityKit
#endif

public struct MobileCommandLiveActivityPresentation: Equatable, Sendable {
  public var commandID: String
  public var commandTitle: String
  public var stationName: String
  public var status: String
  public var detail: String
  public var staleDate: Date?
  public var systemImageName: String

  public init(
    commandID: String,
    commandTitle: String,
    stationName: String,
    status: String,
    detail: String,
    staleDate: Date?,
    systemImageName: String = "terminal"
  ) {
    self.commandID = commandID
    self.commandTitle = commandTitle
    self.stationName = stationName
    self.status = status
    self.detail = detail
    self.staleDate = staleDate
    self.systemImageName = systemImageName
  }

  public init(command: MobileCommandRecord, stationName: String, now: Date) {
    self.init(
      commandID: command.id,
      commandTitle: command.title,
      stationName: stationName,
      status: command.status.title,
      detail: Self.detail(for: command, now: now),
      staleDate: command.expiresAt,
      systemImageName: "terminal"
    )
  }

  public init(
    criticalDecision: MobileAttentionItem,
    stationName: String,
    staleDate: Date?
  ) {
    self.init(
      commandID: "critical-decision-\(criticalDecision.stationID)-\(criticalDecision.id)",
      commandTitle: criticalDecision.title,
      stationName: stationName,
      status: criticalDecision.kind.title,
      detail: criticalDecision.subtitle,
      staleDate: staleDate,
      systemImageName: "exclamationmark.octagon"
    )
  }

  public static func primaryActivity(
    in snapshot: MobileMirrorSnapshot,
    preferredStationID: String? = nil,
    now: Date = .now
  ) -> Self? {
    let activeCommand = selectedActiveCommand(
      in: snapshot,
      preferredStationID: preferredStationID,
      now: now
    )
    if let activeCommand, activeCommand.status == .running {
      return presentation(for: activeCommand, in: snapshot, now: now)
    }
    return criticalDecision(in: snapshot, preferredStationID: preferredStationID)
      ?? activeCommand.map { presentation(for: $0, in: snapshot, now: now) }
  }

  public static func activeCommand(
    in snapshot: MobileMirrorSnapshot,
    preferredStationID: String? = nil,
    now: Date = .now
  ) -> Self? {
    guard
      let command = selectedActiveCommand(
        in: snapshot,
        preferredStationID: preferredStationID,
        now: now
      )
    else {
      return nil
    }
    return presentation(for: command, in: snapshot, now: now)
  }

  private static func selectedActiveCommand(
    in snapshot: MobileMirrorSnapshot,
    preferredStationID: String? = nil,
    now: Date = .now
  ) -> MobileCommandRecord? {
    let activeCommands = snapshot.commands.filter {
      $0.isActiveMobileQueueCommand(now: now)
    }
    guard !activeCommands.isEmpty else {
      return nil
    }

    let stationCommands: [MobileCommandRecord]
    if let preferredStationID, !preferredStationID.isEmpty {
      let preferredCommands = activeCommands.filter { $0.stationID == preferredStationID }
      stationCommands = preferredCommands.isEmpty ? activeCommands : preferredCommands
    } else {
      stationCommands = activeCommands
    }

    return stationCommands.min(by: commandPrecedes)
  }

  private static func presentation(
    for command: MobileCommandRecord,
    in snapshot: MobileMirrorSnapshot,
    now: Date
  ) -> Self {
    let stationName = snapshot.station(id: command.stationID)?.displayName ?? "Mac relay"
    return Self(command: command, stationName: stationName, now: now)
  }

  private static func criticalDecision(
    in snapshot: MobileMirrorSnapshot,
    preferredStationID: String? = nil
  ) -> Self? {
    let criticalDecisions = snapshot.sortedAttention.filter {
      $0.kind == .acpDecision && $0.severity == .critical
    }
    guard !criticalDecisions.isEmpty else {
      return nil
    }

    let stationDecisions: [MobileAttentionItem]
    if let preferredStationID, !preferredStationID.isEmpty {
      let preferredDecisions = criticalDecisions.filter { $0.stationID == preferredStationID }
      stationDecisions = preferredDecisions.isEmpty ? criticalDecisions : preferredDecisions
    } else {
      stationDecisions = criticalDecisions
    }

    guard let decision = stationDecisions.first else {
      return nil
    }
    let stationName = snapshot.station(id: decision.stationID)?.displayName ?? "Mac relay"
    return Self(
      criticalDecision: decision,
      stationName: stationName,
      staleDate: snapshot.expiresAt
    )
  }

  private static func commandPrecedes(
    _ lhs: MobileCommandRecord,
    _ rhs: MobileCommandRecord
  ) -> Bool {
    if lhs.status.liveActivityRank != rhs.status.liveActivityRank {
      return lhs.status.liveActivityRank < rhs.status.liveActivityRank
    }
    if lhs.risk.liveActivityRank != rhs.risk.liveActivityRank {
      return lhs.risk.liveActivityRank < rhs.risk.liveActivityRank
    }
    return lhs.updatedAt > rhs.updatedAt
  }

  private static func detail(for command: MobileCommandRecord, now: Date) -> String {
    if let receipt = command.receipt,
      !receipt.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return receipt.message
    }

    switch command.status {
    case .queued:
      let remaining = max(0, command.expiresAt.timeIntervalSince(now))
      let minutes = max(1, Int((remaining / 60).rounded(.up)))
      return "Expires in \(minutes)m"
    case .accepted:
      return "Accepted by Mac relay"
    case .running:
      return "Executing revision \(command.target.targetRevision)"
    case .draft, .succeeded, .failed, .expired, .cancelled:
      return command.confirmationText
    }
  }
}

extension MobileCommandRecord {
  public func isActiveMobileQueueCommand(now: Date = .now) -> Bool {
    status != .draft && !status.isTerminal && !isExpired(now: now)
  }
}

extension MobileCommandStatus {
  fileprivate var liveActivityRank: Int {
    switch self {
    case .running: 0
    case .accepted: 1
    case .queued: 2
    case .draft: 3
    case .succeeded, .failed, .expired, .cancelled: 4
    }
  }
}

extension MobileCommandRisk {
  fileprivate var liveActivityRank: Int {
    switch self {
    case .destructive: 0
    case .high: 1
    case .low: 2
    }
  }
}

#if canImport(ActivityKit) && os(iOS)
  public struct MobileCommandActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
      public var commandID: String
      public var status: String
      public var detail: String

      public init(commandID: String, status: String, detail: String) {
        self.commandID = commandID
        self.status = status
        self.detail = detail
      }

      public init(presentation: MobileCommandLiveActivityPresentation) {
        self.init(
          commandID: presentation.commandID,
          status: presentation.status,
          detail: presentation.detail
        )
      }
    }

    public var commandID: String
    public var commandTitle: String
    public var stationName: String
    public var systemImageName: String

    private enum CodingKeys: String, CodingKey {
      case commandID
      case commandTitle
      case stationName
      case systemImageName
    }

    public init(
      commandID: String,
      commandTitle: String,
      stationName: String,
      systemImageName: String = "terminal"
    ) {
      self.commandID = commandID
      self.commandTitle = commandTitle
      self.stationName = stationName
      self.systemImageName = systemImageName
    }

    public init(presentation: MobileCommandLiveActivityPresentation) {
      self.init(
        commandID: presentation.commandID,
        commandTitle: presentation.commandTitle,
        stationName: presentation.stationName,
        systemImageName: presentation.systemImageName
      )
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        commandID: try container.decode(String.self, forKey: .commandID),
        commandTitle: try container.decode(String.self, forKey: .commandTitle),
        stationName: try container.decode(String.self, forKey: .stationName),
        systemImageName: try container.decodeIfPresent(String.self, forKey: .systemImageName)
          ?? "terminal"
      )
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(commandID, forKey: .commandID)
      try container.encode(commandTitle, forKey: .commandTitle)
      try container.encode(stationName, forKey: .stationName)
      try container.encode(systemImageName, forKey: .systemImageName)
    }
  }
#endif
