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
            checkSuiteID: check.checkSuiteID
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
