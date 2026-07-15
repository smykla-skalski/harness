import Foundation
import HarnessMonitorKit
import Observation

struct TaskBoardApprovalGrantRefreshID: Hashable {
  let heldIntentIDs: [String]
  let activeCanvasID: String?
  let activeRevision: UInt64?
  let lastRunID: String?
  let evaluationFingerprint: TaskBoardApprovalEvaluationFingerprint?
  let localGeneration: UInt64
}

struct TaskBoardApprovalEvaluationFingerprint: Hashable, Sendable {
  let recordCount: Int
  let contentFingerprint: Int

  init(evaluation: TaskBoardEvaluationSummary) {
    var summaryHasher = Hasher()
    summaryHasher.combine(evaluation.total)
    summaryHasher.combine(evaluation.evaluated)
    summaryHasher.combine(evaluation.updated)
    summaryHasher.combine(evaluation.blocked)
    summaryHasher.combine(evaluation.failed)
    var combined = summaryHasher.finalize()
    for record in evaluation.records {
      var recordHasher = Hasher()
      recordHasher.combine(record.boardItemId)
      recordHasher.combine(record.outcome.rawValue)
      recordHasher.combine(record.updated)
      combined = combined &+ recordHasher.finalize()
    }
    self.recordCount = evaluation.records.count
    self.contentFingerprint = combined
  }
}

struct TaskBoardApprovalGrantPresentation: Identifiable, Sendable {
  let grant: PolicyApprovalGrant
  let expiresAt: Date?

  var id: String { grant.id }

  init(grant: PolicyApprovalGrant) {
    self.grant = grant
    self.expiresAt = Self.expirationDate(for: grant)
  }

  private static func expirationDate(for grant: PolicyApprovalGrant) -> Date? {
    guard
      let expirySeconds = grant.expirySeconds,
      let createdAt = TaskBoardApprovalGrantDateParser.parse(grant.createdAt)
    else {
      return nil
    }
    return createdAt.addingTimeInterval(TimeInterval(expirySeconds))
  }
}

private enum TaskBoardApprovalGrantDateParser {
  private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let standard = Date.ISO8601FormatStyle()

  static func parse(_ value: String) -> Date? {
    (try? fractional.parse(value)) ?? (try? standard.parse(value))
  }
}

@MainActor
@Observable
final class TaskBoardApprovalGrantsState {
  enum Confirmation: Identifiable {
    case approve(grantID: String)
    case reject(grantID: String)
    case revoke(grantID: String)

    var id: String {
      switch self {
      case .approve(let grantID):
        "approve-\(grantID)"
      case .reject(let grantID):
        "reject-\(grantID)"
      case .revoke(let grantID):
        "revoke-\(grantID)"
      }
    }
  }

  var grants: [TaskBoardApprovalGrantPresentation] = []
  var isLoading = false
  var activeGrantID: String?
  var confirmation: Confirmation?
  private var requestedRefreshGeneration: UInt64 = 0

  func requestRefresh() -> UInt64? {
    requestedRefreshGeneration &+= 1
    guard !isLoading else { return nil }
    isLoading = true
    return requestedRefreshGeneration
  }

  func completeRefresh(
    generation: UInt64,
    grants: [PolicyApprovalGrant]?
  ) -> UInt64? {
    if generation == requestedRefreshGeneration, let grants {
      replace(with: grants)
    }
    guard generation == requestedRefreshGeneration else {
      return requestedRefreshGeneration
    }
    isLoading = false
    return nil
  }

  func replace(with grants: [PolicyApprovalGrant]) {
    self.grants = grants.map(TaskBoardApprovalGrantPresentation.init(grant:))
  }

  func apply(_ grant: PolicyApprovalGrant) {
    grants.removeAll { $0.id == grant.id }
    if grant.state == .pending {
      grants.append(TaskBoardApprovalGrantPresentation(grant: grant))
    }
  }
}
