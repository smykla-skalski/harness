import Foundation

public struct MobileMirrorSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var revision: Int64
  public var generatedAt: Date
  public var expiresAt: Date
  public var stations: [MobileStationSummary]
  public var attention: [MobileAttentionItem]
  public var sessions: [MobileSessionSummary]
  public var reviews: [MobileReviewSummary]
  public var taskBoardItems: [MobileTaskBoardSummary]
  public var commands: [MobileCommandRecord]
  public var trustedDevices: [MobileDeviceDescriptor]

  public init(
    schemaVersion: Int = 1,
    revision: Int64,
    generatedAt: Date,
    expiresAt: Date,
    stations: [MobileStationSummary],
    attention: [MobileAttentionItem],
    sessions: [MobileSessionSummary],
    reviews: [MobileReviewSummary],
    taskBoardItems: [MobileTaskBoardSummary] = [],
    commands: [MobileCommandRecord],
    trustedDevices: [MobileDeviceDescriptor] = []
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.generatedAt = generatedAt
    self.expiresAt = expiresAt
    self.stations = stations
    self.attention = attention
    self.sessions = sessions
    self.reviews = reviews
    self.taskBoardItems = taskBoardItems
    self.commands = commands
    self.trustedDevices = trustedDevices
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case revision
    case generatedAt
    case expiresAt
    case stations
    case attention
    case sessions
    case reviews
    case taskBoardItems
    case commands
    case trustedDevices
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
      revision: try container.decode(Int64.self, forKey: .revision),
      generatedAt: try container.decode(Date.self, forKey: .generatedAt),
      expiresAt: try container.decode(Date.self, forKey: .expiresAt),
      stations: try container.decode([MobileStationSummary].self, forKey: .stations),
      attention: try container.decode([MobileAttentionItem].self, forKey: .attention),
      sessions: try container.decode([MobileSessionSummary].self, forKey: .sessions),
      reviews: try container.decode([MobileReviewSummary].self, forKey: .reviews),
      taskBoardItems: try container.decodeIfPresent(
        [MobileTaskBoardSummary].self,
        forKey: .taskBoardItems
      ) ?? [],
      commands: try container.decode([MobileCommandRecord].self, forKey: .commands),
      trustedDevices: try container.decodeIfPresent(
        [MobileDeviceDescriptor].self,
        forKey: .trustedDevices
      ) ?? []
    )
  }

  public var needsYouCount: Int {
    sortedAttention.filter(\.needsUserAction).count
  }

  public var sortedAttention: [MobileAttentionItem] {
    cockpitAttention.sorted {
      if $0.severity.rank != $1.severity.rank {
        return $0.severity.rank < $1.severity.rank
      }
      return $0.updatedAt > $1.updatedAt
    }
  }

  public var cockpitAttention: [MobileAttentionItem] {
    var itemsByID: [String: MobileAttentionItem] = [:]
    var orderedIDs: [String] = []
    for item in attention {
      if itemsByID[item.id] == nil {
        orderedIDs.append(item.id)
      }
      itemsByID[item.id] = item
    }
    for item in synthesizedAttentionItems() where itemsByID[item.id] == nil {
      orderedIDs.append(item.id)
      itemsByID[item.id] = item
    }
    return orderedIDs.compactMap { itemsByID[$0] }
  }

  public func taskBoardItems(for stationID: String) -> [MobileTaskBoardSummary] {
    taskBoardItems
      .filter { stationID.isEmpty || $0.stationID == stationID }
      .sorted { lhs, rhs in
        if lhs.needsYou != rhs.needsYou {
          return lhs.needsYou && !rhs.needsYou
        }
        return lhs.updatedAt > rhs.updatedAt
      }
  }

  public func mergingStationSnapshot(
    _ stationSnapshot: Self,
    stationID: String,
    defaultStationID: String? = nil
  ) -> Self {
    guard !stationID.isEmpty else {
      return stationSnapshot.normalizingDefaultStation(defaultStationID: defaultStationID)
    }

    var stationIDs = Set(stationSnapshot.stations.map(\.id))
    stationIDs.insert(stationID)

    var merged = self
    merged.schemaVersion = max(schemaVersion, stationSnapshot.schemaVersion)
    merged.revision = max(revision, stationSnapshot.revision)
    merged.generatedAt = max(generatedAt, stationSnapshot.generatedAt)
    merged.expiresAt = max(expiresAt, stationSnapshot.expiresAt)
    merged.stations.removeAll { stationIDs.contains($0.id) }
    merged.attention.removeAll { stationIDs.contains($0.stationID) }
    merged.sessions.removeAll { stationIDs.contains($0.stationID) }
    merged.reviews.removeAll { stationIDs.contains($0.stationID) }
    merged.taskBoardItems.removeAll { stationIDs.contains($0.stationID) }
    merged.commands.removeAll { stationIDs.contains($0.stationID) }
    merged.stations.append(contentsOf: stationSnapshot.stations)
    merged.attention.append(contentsOf: stationSnapshot.attention)
    merged.sessions.append(contentsOf: stationSnapshot.sessions)
    merged.reviews.append(contentsOf: stationSnapshot.reviews)
    merged.taskBoardItems.append(contentsOf: stationSnapshot.taskBoardItems)
    merged.commands.append(contentsOf: stationSnapshot.commands)
    merged.trustedDevices = trustedDevices.mergingTrustedDevices(stationSnapshot.trustedDevices)
    return merged.normalizingDefaultStation(defaultStationID: defaultStationID)
  }

  public func removingStationData(
    for stationIDs: [String],
    defaultStationID: String? = nil
  ) -> Self {
    let stationIDs = Set(
      stationIDs
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    guard !stationIDs.isEmpty else {
      return normalizingDefaultStation(defaultStationID: defaultStationID)
    }

    var pruned = self
    pruned.stations.removeAll { stationIDs.contains($0.id) }
    pruned.attention.removeAll { stationIDs.contains($0.stationID) }
    pruned.sessions.removeAll { stationIDs.contains($0.stationID) }
    pruned.reviews.removeAll { stationIDs.contains($0.stationID) }
    pruned.taskBoardItems.removeAll { stationIDs.contains($0.stationID) }
    pruned.commands.removeAll { stationIDs.contains($0.stationID) }
    return pruned.normalizingDefaultStation(defaultStationID: defaultStationID)
  }

  public func keepingStationData(
    for stationIDs: [String],
    defaultStationID: String? = nil
  ) -> Self {
    let stationIDs = Set(
      stationIDs
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    var scoped = self
    scoped.stations.removeAll { stationIDs.isEmpty || !stationIDs.contains($0.id) }
    scoped.attention.removeAll { stationIDs.isEmpty || !stationIDs.contains($0.stationID) }
    scoped.sessions.removeAll { stationIDs.isEmpty || !stationIDs.contains($0.stationID) }
    scoped.reviews.removeAll { stationIDs.isEmpty || !stationIDs.contains($0.stationID) }
    scoped.taskBoardItems.removeAll { stationIDs.isEmpty || !stationIDs.contains($0.stationID) }
    scoped.commands.removeAll { stationIDs.isEmpty || !stationIDs.contains($0.stationID) }
    return scoped.normalizingDefaultStation(defaultStationID: defaultStationID)
  }

  public static func empty(now: Date = .now) -> Self {
    Self(
      revision: 0,
      generatedAt: now,
      expiresAt: now,
      stations: [],
      attention: [],
      sessions: [],
      reviews: [],
      commands: []
    )
  }

  private func normalizingDefaultStation(
    defaultStationID: String?
  ) -> Self {
    var normalized = self
    let requestedDefaultStationID = defaultStationID.flatMap { stationID in
      stationID.isEmpty ? nil : stationID
    }
    let resolvedDefaultStationID =
      requestedDefaultStationID
      ?? stations.first(where: \.defaultStation)?.id
      ?? stations.first?.id
    normalized.stations = stations.map { station in
      var station = station
      station.defaultStation = station.id == resolvedDefaultStationID
      return station
    }
    return normalized
  }

  private func synthesizedAttentionItems() -> [MobileAttentionItem] {
    let existing = ExistingAttentionCoverage(attention: attention)
    var items: [MobileAttentionItem] = []
    items.append(contentsOf: synthesizedReviewAttention(existing: existing))
    items.append(contentsOf: synthesizedTaskBoardAttention(existing: existing))
    items.append(contentsOf: synthesizedAgentAttention(existing: existing))
    items.append(contentsOf: synthesizedSessionAttention(existing: existing))
    items.append(contentsOf: synthesizedCommandAttention(existing: existing))
    items.append(contentsOf: synthesizedStationHealthAttention(existing: existing))
    return items
  }

  private func synthesizedReviewAttention(
    existing: ExistingAttentionCoverage
  ) -> [MobileAttentionItem] {
    reviews.compactMap { review in
      guard review.needsYou, !existing.reviewIDs.contains(review.id) else {
        return nil
      }
      return MobileAttentionItem(
        id: "derived-review-\(review.id)",
        stationID: review.stationID,
        kind: .pullRequest,
        severity: review.policyBlocked == true ? .critical : .warning,
        title: String(localized: "Review \(review.repository) #\(review.number)", bundle: .module),
        subtitle: review.title,
        updatedAt: review.updatedAt,
        commandKind: review.viewerCanUpdate ? .pullRequestApprove : nil,
        target: MobileCommandTarget(
          stationID: review.stationID,
          reviewID: review.id,
          targetRevision: revision
        ),
        commandPayload: review.commandPayload
      )
    }
  }

  private func synthesizedTaskBoardAttention(
    existing: ExistingAttentionCoverage
  ) -> [MobileAttentionItem] {
    taskBoardItems.compactMap { item in
      guard item.needsYou, !existing.taskIDs.contains(item.id) else {
        return nil
      }
      let kind: MobileCommandKind =
        item.status == "plan_review" ? .taskBoardPlanApproval : .taskBoardDispatch
      let draft = item.commandDraft(kind: kind, targetRevision: revision)
      return MobileAttentionItem(
        id: "derived-task-\(item.id)",
        stationID: item.stationID,
        kind: .taskBoard,
        severity: item.priority == "critical" ? .critical : .warning,
        title: item.title,
        subtitle: item.statusTitle,
        updatedAt: item.updatedAt,
        commandKind: kind,
        target: draft.target,
        commandPayload: draft.payload
      )
    }
  }

  private func synthesizedAgentAttention(
    existing: ExistingAttentionCoverage
  ) -> [MobileAttentionItem] {
    sessions.flatMap(\.agents).compactMap { agent in
      let needsAttention =
        agent.isBlocked || agent.pendingApprovalCount > 0 || agent.pendingPermissionCount > 0
      guard needsAttention, !existing.agentIDs.contains(agent.id) else {
        return nil
      }
      return MobileAttentionItem(
        id: "derived-agent-\(agent.id)",
        stationID: agent.stationID,
        kind: .blockedAgent,
        severity: agent.pendingPermissionCount > 0 ? .critical : .warning,
        title: String(localized: "\(agent.displayName) is waiting", bundle: .module),
        subtitle: agent.summary.isEmpty ? agent.status : agent.summary,
        updatedAt: agent.lastActivityAt,
        commandKind: agent.isActive ? .agentPrompt : nil,
        target: MobileCommandTarget(
          stationID: agent.stationID,
          sessionID: agent.sessionID,
          agentID: agent.id,
          targetRevision: revision
        )
      )
    }
  }

  private func synthesizedSessionAttention(
    existing: ExistingAttentionCoverage
  ) -> [MobileAttentionItem] {
    sessions.compactMap { session in
      guard session.blockedAgentCount > 0, !existing.sessionIDs.contains(session.id) else {
        return nil
      }
      return MobileAttentionItem(
        id: "derived-session-\(session.id)",
        stationID: session.stationID,
        kind: .blockedAgent,
        severity: .warning,
        title: String(
          localized: "\(session.blockedAgentCount) agents waiting", bundle: .module),
        subtitle: session.title,
        updatedAt: session.lastActivityAt,
        target: MobileCommandTarget(
          stationID: session.stationID,
          sessionID: session.id,
          targetRevision: revision
        )
      )
    }
  }

  private func synthesizedCommandAttention(
    existing: ExistingAttentionCoverage
  ) -> [MobileAttentionItem] {
    commands.compactMap { command in
      guard command.status == .failed || command.status == .expired,
        !existing.commandIDs.contains(command.id)
      else {
        return nil
      }
      return MobileAttentionItem(
        id: "derived-command-\(command.id)",
        stationID: command.stationID,
        kind: .commandFailure,
        severity: command.risk == .destructive ? .critical : .warning,
        title: "\(command.title) \(command.status.title.lowercased())",
        subtitle: command.receipt?.message ?? command.confirmationText,
        updatedAt: command.updatedAt,
        target: command.target,
        commandPayload: command.payload
      )
    }
  }

  private func synthesizedStationHealthAttention(
    existing: ExistingAttentionCoverage
  ) -> [MobileAttentionItem] {
    stations.compactMap { station in
      guard station.state != .online, !existing.stationHealthIDs.contains(station.id) else {
        return nil
      }
      return MobileAttentionItem(
        id: "derived-station-\(station.id)-\(station.state.rawValue)",
        stationID: station.id,
        kind: .stationHealth,
        severity: station.state == .offline ? .critical : .warning,
        title: String(
          localized: "\(station.displayName) is \(station.state.title.lowercased())",
          bundle: .module),
        subtitle: String(
          localized: "Last seen \(station.lastSeenAt.formatted(.relative(presentation: .numeric)))",
          bundle: .module),
        updatedAt: station.lastSeenAt
      )
    }
  }
}
