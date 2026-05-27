import Foundation

extension ReviewItem {
  public var target: ReviewTarget {
    ReviewTarget(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      url: url,
      state: state,
      isDraft: isDraft,
      headSha: headSha,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      requiredFailedCheckNames: requiredFailedCheckNames,
      viewerCanMergeAsAdmin: viewerCanMergeAsAdmin,
      checkSuiteIDs: checks.compactMap(\.checkSuiteID),
      viewerCanUpdate: viewerCanUpdate
    )
  }

  public var rerunTarget: ReviewTarget {
    ReviewTarget(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      url: url,
      state: state,
      isDraft: isDraft,
      headSha: headSha,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      requiredFailedCheckNames: requiredFailedCheckNames,
      viewerCanMergeAsAdmin: viewerCanMergeAsAdmin,
      checkSuiteIDs: rerunnableCheckSuiteIDs,
      viewerCanUpdate: viewerCanUpdate
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
      return "No checks are reported for this review."
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
    viewerCanUpdate && (isAutoApprovable || isAutoMergeable || isApprovedAndMergeable)
  }

  // Approved but checks not yet passing — server preview decides whether to merge.
  // Keeps the button enabled so the user gets a meaningful response instead of silence.
  var isApprovedAndMergeable: Bool {
    viewerCanUpdate
      && state == .open
      && !isDraft
      && reviewStatus == .approved
      && mergeable != .conflicting
      && !policyBlocked
  }

  public var canAddReviewLabel: Bool {
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

extension ReviewCheck {
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

extension ReviewTarget {
  public var isAutoApprovable: Bool {
    viewerCanUpdate
      && state == .open
      && checkStatus == .success
      && (reviewStatus == .reviewRequired || reviewStatus == .none)
      && mergeable != .conflicting
  }

  public var isAutoMergeable: Bool {
    viewerCanUpdate
      && state == .open
      && !isDraft
      && (reviewStatus == .approved || reviewStatus == .none)
      && checkStatus == .success
      && mergeable != .conflicting
      && !policyBlocked
  }
}

extension ReviewItem {
  public func replacing(
    state: ReviewPullRequestState? = nil,
    reviewStatus: ReviewReviewStatus? = nil,
    checkStatus: ReviewCheckStatus? = nil,
    labels: [String]? = nil,
    checks: [ReviewCheck]? = nil,
    policyBlocked: Bool? = nil
  ) -> Self {
    ReviewItem(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      title: title,
      url: url,
      authorLogin: authorLogin,
      authorAvatarURL: authorAvatarURL,
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

extension ReviewItem {
  /// Canonical human-readable deep-link id ("owner/repo#number") for
  /// `harness://` links. Distinct from `pullRequestID`, which is the opaque
  /// GitHub node id used as the stable identity/key. `nil` when
  /// `repository`/`number` cannot form a valid id.
  public var pullRequestDeepLinkID: String? {
    HarnessMonitorDeepLinkRouter.pullRequestDeepLinkID(
      repositoryFullName: repository,
      number: number
    )
  }

  /// True when `selector` identifies this item, whether it is the node-id
  /// `pullRequestID` (Open Anything, App Intents) or the deep-link slug
  /// ("owner/repo#number") carried by a `harness://` link.
  public func matchesDeepLinkSelector(_ selector: String) -> Bool {
    pullRequestID == selector || pullRequestDeepLinkID == selector
  }
}
