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

  public var canAttemptRerunChecks: Bool {
    viewerCanUpdate && hasRerunnableChecks
  }

  public var rerunChecksUnavailableReason: String? {
    guard !checks.isEmpty else {
      return "No checks are reported for this dependency update."
    }
    guard checks.contains(where: { $0.checkSuiteID != nil }) else {
      return "GitHub did not provide check suite IDs for these checks."
    }
    guard checks.contains(where: \.isRerunnable) else {
      return "Only failed or timed-out completed check runs can be rerun."
    }
    return nil
  }

  public var canAttemptManualApproval: Bool {
    guard viewerCanUpdate else { return false }
    guard state == .open else { return false }
    return reviewStatus == .reviewRequired || reviewStatus == .none
  }

  public var canAttemptManualMerge: Bool {
    viewerCanUpdate && state == .open && !isDraft && mergeable != .conflicting
  }

  public var canRunAutoMode: Bool {
    viewerCanUpdate && (isAutoApprovable || isAutoMergeable)
  }

  public var canAddDependencyLabel: Bool {
    viewerCanUpdate && state == .open
  }

  public var canRebaseViaBot: Bool {
    viewerCanUpdate && state == .open
  }

  public var canStartFixCI: Bool {
    checkStatus == .failure
  }

  public var hasRequiredFailedChecks: Bool {
    !requiredFailedCheckNames.isEmpty
  }

  public var requiresAdminMergeForRequiredFailures: Bool {
    canAttemptManualMerge
      && viewerCanMergeAsAdmin
      && hasRequiredFailedChecks
      && reviewStatus != .changesRequested
      && !policyBlocked
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
  public var detailsWebURL: URL? {
    guard let detailsURL else { return nil }
    let trimmed = detailsURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http"
    else {
      return nil
    }
    return url
  }

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

  public var rerunUnavailableReason: String? {
    guard checkSuiteID != nil else {
      return "GitHub did not provide a check suite ID for this check."
    }
    guard status == .completed else {
      return "Only completed check runs can be rerun."
    }
    switch conclusion {
    case .failure, .timedOut:
      return nil
    default:
      return "Only failed or timed-out check runs can be rerun."
    }
  }
}

extension DependencyUpdateTarget {
  public var isAutoApprovable: Bool {
    checkStatus == .success
      && (reviewStatus == .reviewRequired || reviewStatus == .none)
      && mergeable != .conflicting
  }

  public var isAutoMergeable: Bool {
    (reviewStatus == .approved || reviewStatus == .none)
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
      updatedAt: updatedAt,
      requiredFailedCheckNames: requiredFailedCheckNames,
      viewerCanUpdate: viewerCanUpdate,
      viewerCanMergeAsAdmin: viewerCanMergeAsAdmin
    )
  }
}
