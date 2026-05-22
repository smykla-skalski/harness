import HarnessMonitorKit

struct DashboardDependencyAttentionReasonCounts {
  var requiredFailures = 0
  var optionalFailures = 0
  var policyBlocked = 0
  var changesRequested = 0
  var conflicts = 0

  mutating func record(_ item: DependencyUpdateItem) {
    if item.hasRequiredFailedChecks {
      requiredFailures += 1
    } else if item.checkStatus == .failure {
      optionalFailures += 1
    }
    if item.policyBlocked {
      policyBlocked += 1
    }
    if item.reviewStatus == .changesRequested {
      changesRequested += 1
    }
    if item.mergeable == .conflicting {
      conflicts += 1
    }
  }
}
