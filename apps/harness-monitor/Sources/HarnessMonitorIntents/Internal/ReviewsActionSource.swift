import Foundation
import HarnessMonitorKit

public protocol ReviewsActionSource: Sendable {
  func approve(pullRequestID: String) async throws
  func merge(pullRequestID: String, method: TaskBoardGitHubMergeMethod) async throws
  func rerunChecks(pullRequestID: String) async throws
  func addLabel(pullRequestID: String, label: String) async throws
}

struct DaemonReviewsActionSource: ReviewsActionSource {
  let environment: HarnessMonitorEnvironment

  init(environment: HarnessMonitorEnvironment = .current) {
    self.environment = environment
  }

  func approve(pullRequestID: String) async throws {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    try await client.approve(pullRequestID: pullRequestID)
  }

  func merge(pullRequestID: String, method: TaskBoardGitHubMergeMethod) async throws {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    try await client.merge(pullRequestID: pullRequestID, method: method)
  }

  func rerunChecks(pullRequestID: String) async throws {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    try await client.rerunChecks(pullRequestID: pullRequestID)
  }

  func addLabel(pullRequestID: String, label: String) async throws {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    try await client.addLabel(pullRequestID: pullRequestID, label: label)
  }
}
