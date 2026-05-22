import Foundation

extension PreviewHarnessClientState {
  func catalogDependencyUpdateRepositories(
    request: DependencyUpdatesRepositoryCatalogRequest
  ) -> DependencyUpdatesRepositoryCatalogResponse {
    let organization = request.organization.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let knownRepositories =
      dependencyUpdateItems.map(\.repository)
      + taskBoardOrchestratorSettings.githubInbox.repositories
    let repositories = Array(
      Set(
        knownRepositories.filter { repository in
          repository.split(separator: "/", maxSplits: 1).first?.lowercased() == organization
        }
      )
    ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return DependencyUpdatesRepositoryCatalogResponse(
      organization: organization,
      repositories: repositories
    )
  }

  func currentDependencyUpdates(
    request: DependencyUpdatesQueryRequest
  ) -> DependencyUpdatesQueryResponse {
    let items = dependencyUpdateItems.filter { item in
      let owner = item.repository.split(separator: "/").first.map(String.init)
      let matchesOrganizations =
        request.organizations.isEmpty
        || owner.map { request.organizations.contains($0) } == true
      let matchesRepositories =
        request.repositories.isEmpty
        || request.repositories.contains(item.repository)
      let matchesExclusions = !request.excludeRepositories.contains(item.repository)
      let matchesAuthors = request.authors.isEmpty || request.authors.contains(item.authorLogin)
      return matchesOrganizations && matchesRepositories && matchesExclusions && matchesAuthors
    }
    return DependencyUpdatesQueryResponse(
      fetchedAt: Self.mutationTimestamp,
      fromCache: false,
      summary: DependencyUpdatesSummary(items: items),
      items: items
    )
  }

  func approveDependencyUpdates(
    request: DependencyUpdatesApproveRequest
  ) -> DependencyUpdatesActionResponse {
    for target in request.targets {
      dependencyUpdateItems = dependencyUpdateItems.map { item in
        guard item.pullRequestID == target.pullRequestID else { return item }
        return item.replacing(reviewStatus: .approved)
      }
    }
    return previewActionResponse(
      summary: "Approved dependency updates",
      action: .approve,
      request.targets
    )
  }

  func mergeDependencyUpdates(
    request: DependencyUpdatesMergeRequest
  ) -> DependencyUpdatesActionResponse {
    let mergedIDs = Set(request.targets.map(\.pullRequestID))
    dependencyUpdateItems.removeAll { mergedIDs.contains($0.pullRequestID) }
    return previewActionResponse(
      summary: "Merged dependency updates",
      action: .merge,
      request.targets
    )
  }

  func rerunDependencyUpdateChecks(
    request: DependencyUpdatesRerunChecksRequest
  ) -> DependencyUpdatesActionResponse {
    for target in request.targets {
      dependencyUpdateItems = dependencyUpdateItems.map { item in
        guard item.pullRequestID == target.pullRequestID else { return item }
        let rerunChecks = item.checks.map { check in
          guard target.checkSuiteIDs.contains(check.checkSuiteID ?? "") else { return check }
          return DependencyUpdateCheck(
            name: check.name,
            status: .inProgress,
            conclusion: .none,
            checkSuiteID: check.checkSuiteID,
            detailsURL: check.detailsURL
          )
        }
        return item.replacing(checkStatus: .pending, checks: rerunChecks)
      }
    }
    return previewActionResponse(
      summary: "Reran dependency update checks",
      action: .rerunChecks,
      request.targets
    )
  }

  func addDependencyUpdateLabel(
    request: DependencyUpdatesLabelRequest
  ) -> DependencyUpdatesActionResponse {
    for target in request.targets {
      dependencyUpdateItems = dependencyUpdateItems.map { item in
        guard item.pullRequestID == target.pullRequestID else { return item }
        var labels = item.labels
        if !labels.contains(request.label) {
          labels.append(request.label)
          labels.sort()
        }
        return item.replacing(labels: labels)
      }
    }
    return previewActionResponse(
      summary: "Labeled dependency updates",
      action: .addLabel,
      request.targets
    )
  }

  func autoDependencyUpdates(
    request: DependencyUpdatesAutoRequest
  ) -> DependencyUpdatesActionResponse {
    for target in request.targets where target.isAutoApprovable {
      dependencyUpdateItems = dependencyUpdateItems.map { item in
        guard item.pullRequestID == target.pullRequestID else { return item }
        return item.replacing(reviewStatus: .approved)
      }
    }
    let mergedIDs = Set(request.targets.filter { $0.isAutoMergeable }.map(\.pullRequestID))
    let newlyApprovedIDs = Set(request.targets.filter { $0.isAutoApprovable }.map(\.pullRequestID))
    dependencyUpdateItems.removeAll {
      mergedIDs.contains($0.pullRequestID) || newlyApprovedIDs.contains($0.pullRequestID)
    }
    return previewActionResponse(summary: "Auto mode finished", action: .autoMerge, request.targets)
  }

  func clearDependencyUpdatesCache() -> DependencyUpdatesCacheClearResponse {
    DependencyUpdatesCacheClearResponse(clearedEntries: 1)
  }

  func refreshDependencyUpdates(
    request: DependencyUpdatesRefreshRequest
  ) -> DependencyUpdatesRefreshResponse {
    let requestedIDs = Set(request.targets.map(\.pullRequestID))
    let refreshed = dependencyUpdateItems.filter { requestedIDs.contains($0.pullRequestID) }
    let missing = requestedIDs.subtracting(refreshed.map(\.pullRequestID))
    return DependencyUpdatesRefreshResponse(
      fetchedAt: Self.mutationTimestamp,
      items: refreshed,
      missingPullRequestIDs: missing.sorted()
    )
  }

  func fetchDependencyUpdateBody(
    request: DependencyUpdatesBodyRequest
  ) -> DependencyUpdatesBodyResponse {
    let item = dependencyUpdateItems.first { $0.pullRequestID == request.pullRequestID }
    let body =
      item.map {
        """
        Bumps `\($0.repository.split(separator: "/").last ?? "package")` from an older release.

        - Release notes: link
        - Changelog: link

        Closes a tracking issue and keeps dependencies current.
        """
      } ?? ""
    return DependencyUpdatesBodyResponse(
      pullRequestID: request.pullRequestID,
      body: body,
      prUpdatedAt: item?.updatedAt ?? "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:00Z",
      fromCache: false
    )
  }

  func updateDependencyUpdateBody(
    request: DependencyUpdatesBodyUpdateRequest
  ) -> DependencyUpdatesBodyUpdateResponse {
    DependencyUpdatesBodyUpdateResponse(
      pullRequestID: request.pullRequestID,
      outcome: .updated,
      currentBody: request.newBody,
      currentBodySHA256: request.expectedPriorBodySHA256,
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:00Z"
    )
  }

  func commentDependencyUpdates(
    request: DependencyUpdatesCommentRequest
  ) -> DependencyUpdatesActionResponse {
    previewActionResponse(
      summary: "Posted dependency update comment",
      action: .comment,
      request.targets
    )
  }

  private func previewActionResponse(
    summary: String,
    action: DependencyUpdateActionKind,
    _ targets: [DependencyUpdateTarget]
  ) -> DependencyUpdatesActionResponse {
    DependencyUpdatesActionResponse(
      summary: "\(summary): \(targets.count) applied, 0 skipped, 0 failed",
      results: targets.map { target in
        DependencyUpdateActionResult(
          repository: target.repository,
          number: target.number,
          action: action,
          outcome: .applied
        )
      }
    )
  }
}
