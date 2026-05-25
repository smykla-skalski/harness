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

  public init(
    commandID: String,
    commandTitle: String,
    stationName: String,
    status: String,
    detail: String,
    staleDate: Date?
  ) {
    self.commandID = commandID
    self.commandTitle = commandTitle
    self.stationName = stationName
    self.status = status
    self.detail = detail
    self.staleDate = staleDate
  }

  public init(command: MobileCommandRecord, stationName: String, now: Date) {
    self.init(
      commandID: command.id,
      commandTitle: command.title,
      stationName: stationName,
      status: command.status.title,
      detail: Self.detail(for: command, now: now),
      staleDate: command.expiresAt
    )
  }

  public static func activeCommand(
    in snapshot: MobileMirrorSnapshot,
    preferredStationID: String? = nil,
    now: Date = .now
  ) -> Self? {
    let activeCommands = snapshot.commands.filter {
      $0.status != .draft && !$0.status.isTerminal && !$0.isExpired(now: now)
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

    guard let command = stationCommands.min(by: commandPrecedes) else {
      return nil
    }
    let stationName = snapshot.station(id: command.stationID)?.displayName ?? "Mac relay"
    return Self(command: command, stationName: stationName, now: now)
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

    public init(commandID: String, commandTitle: String, stationName: String) {
      self.commandID = commandID
      self.commandTitle = commandTitle
      self.stationName = stationName
    }

    public init(presentation: MobileCommandLiveActivityPresentation) {
      self.init(
        commandID: presentation.commandID,
        commandTitle: presentation.commandTitle,
        stationName: presentation.stationName
      )
    }
  }
#endif
