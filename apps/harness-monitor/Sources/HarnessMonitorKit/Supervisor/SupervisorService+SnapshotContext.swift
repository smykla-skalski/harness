import Foundation

extension SupervisorService {
  func buildSnapshot(now: Date) async -> SessionsSnapshot {
    let snapshot: SessionsSnapshot
    if let store {
      snapshot = await SessionsSnapshot.build(from: store, now: now)
    } else {
      snapshot = SessionsSnapshot(
        id: UUID().uuidString,
        createdAt: now,
        hash: "",
        sessions: [],
        connection: ConnectionSnapshot(
          kind: "disconnected",
          lastMessageAt: nil,
          reconnectAttempt: 0
        )
      )
    }
    return snapshotWithStableDisconnectAnchor(snapshot, now: now)
  }

  func snapshotWithStableDisconnectAnchor(
    _ snapshot: SessionsSnapshot,
    now: Date
  ) -> SessionsSnapshot {
    guard snapshot.connection.kind == "disconnected" else {
      fallbackDisconnectedSince = nil
      fallbackLastMessageAt = nil
      return snapshot
    }
    if let disconnectedSince = snapshot.connection.disconnectedSince {
      fallbackDisconnectedSince = disconnectedSince
      fallbackLastMessageAt = snapshot.connection.lastMessageAt
      return snapshot
    }

    let disconnectedSince = disconnectedAnchor(for: snapshot.connection, now: now)
    fallbackDisconnectedSince = disconnectedSince
    return SessionsSnapshot(
      id: snapshot.id,
      createdAt: snapshot.createdAt,
      hash: snapshot.hash,
      sessions: snapshot.sessions,
      connection: ConnectionSnapshot(
        kind: snapshot.connection.kind,
        lastMessageAt: snapshot.connection.lastMessageAt,
        disconnectedSince: disconnectedSince,
        reconnectAttempt: snapshot.connection.reconnectAttempt
      )
    )
  }

  func disconnectedAnchor(
    for connection: ConnectionSnapshot,
    now: Date
  ) -> Date {
    guard let lastMessageAt = connection.lastMessageAt else {
      fallbackLastMessageAt = nil
      return fallbackDisconnectedSince ?? now
    }
    defer { fallbackLastMessageAt = lastMessageAt }
    guard let fallbackDisconnectedSince, fallbackLastMessageAt == lastMessageAt else {
      return lastMessageAt
    }
    return fallbackDisconnectedSince
  }

  func shouldSuppress(
    _ action: SupervisorAction,
    behavior: RuleDefaultBehavior,
    at now: Date
  ) -> Bool {
    guard action.isAutomaticSideEffect else {
      return false
    }
    return behavior == .cautious || suppressionActive(at: now)
  }

  func suppressionActive(at now: Date) -> Bool {
    if autoActionSuppressionDepth > 0 {
      return true
    }
    return quietHoursWindow?.contains(now) == true
  }

  func makeContext(
    forRuleID ruleID: String,
    now: Date,
    history: PolicyHistoryWindow
  ) async -> PolicyContext {
    PolicyContext(
      now: now,
      lastFiredAt: ruleLastFiredAt[ruleID],
      recentActionKeys: recentActionKeys(forRuleID: ruleID, at: now),
      parameters: await registry.parameters(forRule: ruleID),
      history: history
    )
  }

  func recentActionKeys(forRuleID ruleID: String, at now: Date) -> Set<String> {
    pruneRecentActionKeys(forRuleID: ruleID, at: now)
    var actionKeys = Set<String>()
    if let firedKeys = ruleRecentActionKeys[ruleID]?.keys {
      actionKeys.formUnion(firedKeys)
    }
    if suppressionActive(at: now),
      let suppressedKeys = ruleRecentSuppressedActionKeys[ruleID]?.keys
    {
      actionKeys.formUnion(suppressedKeys)
    }
    return actionKeys
  }

  func pruneRecentActionKeys(forRuleID ruleID: String, at now: Date) {
    let cutoff = now.addingTimeInterval(-Self.recentActionWindow)
    guard var actionKeys = ruleRecentActionKeys[ruleID] else {
      return
    }
    actionKeys = actionKeys.filter { $0.value > cutoff }
    ruleRecentActionKeys[ruleID] = actionKeys.isEmpty ? nil : actionKeys
  }

  func recordSuppressedAction(
    forRuleID ruleID: String,
    action: SupervisorAction,
    suppressedAt: Date
  ) {
    ruleRecentSuppressedActionKeys[ruleID, default: [:]][action.actionKey] = suppressedAt
  }

  func recordFiredActions(
    forRuleID ruleID: String,
    actions: [SupervisorAction],
    firedAt: Date
  ) {
    guard !actions.isEmpty else {
      return
    }
    var actionKeys = ruleRecentActionKeys[ruleID] ?? [:]
    var seenThisBatch = Set<String>()
    for action in actions {
      if !seenThisBatch.insert(action.actionKey).inserted {
        HarnessMonitorLogger.supervisorWarning(
          "supervisor.action.duplicate_key rule=\(ruleID) key=\(action.actionKey)"
        )
      }
      actionKeys[action.actionKey] = firedAt
    }
    ruleRecentActionKeys[ruleID] = actionKeys
    ruleLastFiredAt[ruleID] = firedAt
  }
}
