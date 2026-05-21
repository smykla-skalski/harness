import Foundation

extension DependencyUpdateItem {
  public var target: DependencyUpdateTarget {
    DependencyUpdateTarget(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      url: url,
      headSha: headSha,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      checkSuiteIDs: checks.compactMap(\.checkSuiteID)
    )
  }

  public var rerunTarget: DependencyUpdateTarget {
    DependencyUpdateTarget(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      url: url,
      headSha: headSha,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      checkSuiteIDs: rerunnableCheckSuiteIDs
    )
  }

  public var rerunnableCheckSuiteIDs: [String] {
    var seen = Set<String>()
    return checks.compactMap { check in
      guard check.isRerunnable, let checkSuiteID = check.checkSuiteID else {
        return nil
      }
      guard seen.insert(checkSuiteID).inserted else {
        return nil
      }
      return checkSuiteID
    }
  }

  public var hasRerunnableChecks: Bool {
    !rerunnableCheckSuiteIDs.isEmpty
  }

  public var canAttemptManualApproval: Bool {
    state == .open && reviewStatus == .reviewRequired
  }

  public var canAttemptManualMerge: Bool {
    state == .open && !isDraft && mergeable != .conflicting
  }

  public var canRunAutoMode: Bool {
    isAutoApprovable || isAutoMergeable
  }

  public var canStartFixCI: Bool {
    checkStatus == .failure
  }

  public var isAutoApprovable: Bool {
    target.isAutoApprovable
  }

  public var isAutoMergeable: Bool {
    target.isAutoMergeable
  }

  public var requiresAttention: Bool {
    policyBlocked
      || mergeable == .conflicting
      || reviewStatus == .changesRequested
      || checkStatus == .failure
  }
}

extension DependencyUpdateCheck {
  public var isRerunnable: Bool {
    guard checkSuiteID != nil, status == .completed else {
      return false
    }
    switch conclusion {
    case .failure, .timedOut:
      return true
    default:
      return false
    }
  }
}

extension DependencyUpdateTarget {
  public var isAutoApprovable: Bool {
    checkStatus == .success
      && reviewStatus == .reviewRequired
      && mergeable != .conflicting
  }

  public var isAutoMergeable: Bool {
    reviewStatus == .approved
      && checkStatus == .success
      && mergeable != .conflicting
      && !policyBlocked
  }
}

extension DependencyUpdateItem {
  public func replacing(
    state: DependencyUpdatePullRequestState? = nil,
    reviewStatus: DependencyUpdateReviewStatus? = nil,
    checkStatus: DependencyUpdateCheckStatus? = nil,
    labels: [String]? = nil,
    checks: [DependencyUpdateCheck]? = nil,
    policyBlocked: Bool? = nil
  ) -> Self {
    DependencyUpdateItem(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      title: title,
      url: url,
      authorLogin: authorLogin,
      state: state ?? self.state,
      mergeable: mergeable,
      reviewStatus: reviewStatus ?? self.reviewStatus,
      checkStatus: checkStatus ?? self.checkStatus,
      policyBlocked: policyBlocked ?? self.policyBlocked,
      isDraft: isDraft,
      headSha: headSha,
      labels: labels ?? self.labels,
      checks: checks ?? self.checks,
      reviews: reviews,
      additions: additions,
      deletions: deletions,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}
