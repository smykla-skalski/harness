import Foundation
import HarnessMonitorKit

struct DashboardReviewCheckListPresentation {
  let problemChecks: [ReviewCheck]
  let nonProblemChecks: [ReviewCheck]
  let problemCheckURLs: [URL]
  let allCheckURLs: [URL]
  let problemCheckGroups: [DashboardReviewCheckGroup]
  let nonProblemCheckGroups: [DashboardReviewCheckGroup]
  let visibleNonProblemCheckGroups: [DashboardReviewCheckGroup]
  let hiddenNonProblemCheckCount: Int
  let allPassing: Bool

  init(
    checks: [ReviewCheck],
    visibleNonProblemCheckLimit: Int
  ) {
    var problemChecks: [ReviewCheck] = []
    var nonProblemChecks: [ReviewCheck] = []
    var problemCheckURLs: [URL] = []
    var allCheckURLs: [URL] = []
    var allPassing = !checks.isEmpty

    problemChecks.reserveCapacity(checks.count)
    nonProblemChecks.reserveCapacity(checks.count)
    problemCheckURLs.reserveCapacity(checks.count)
    allCheckURLs.reserveCapacity(checks.count)

    for check in checks {
      let requiresAttention = check.requiresAttention
      if !check.isPassing {
        allPassing = false
      }
      if let detailsWebURL = check.detailsWebURL {
        allCheckURLs.append(detailsWebURL)
        if requiresAttention {
          problemCheckURLs.append(detailsWebURL)
        }
      }
      if requiresAttention {
        problemChecks.append(check)
      } else {
        nonProblemChecks.append(check)
      }
    }

    self.problemChecks = problemChecks
    self.nonProblemChecks = nonProblemChecks
    self.problemCheckURLs = problemCheckURLs
    self.allCheckURLs = allCheckURLs
    problemCheckGroups = dashboardReviewCheckGroups(for: problemChecks)
    nonProblemCheckGroups = dashboardReviewCheckGroups(for: nonProblemChecks)
    visibleNonProblemCheckGroups = dashboardReviewCheckGroups(
      for: nonProblemChecks.prefix(visibleNonProblemCheckLimit)
    )
    hiddenNonProblemCheckCount = max(nonProblemChecks.count - visibleNonProblemCheckLimit, 0)
    self.allPassing = allPassing
  }

  var hasProblemChecks: Bool {
    !problemChecks.isEmpty
  }

  func targetCheckURLs(onlyFailing: Bool) -> [URL] {
    onlyFailing ? problemCheckURLs : allCheckURLs
  }
}

struct DashboardReviewCheckListPresentationKey: Hashable {
  let checks: [ReviewCheck]
  let visibleNonProblemCheckLimit: Int
}

@MainActor
final class DashboardReviewCheckListPresentationCache {
  private var presentations:
    [DashboardReviewCheckListPresentationKey:
      DashboardReviewCheckListPresentation] = [:]
  private var keys: [DashboardReviewCheckListPresentationKey] = []
  private let limit: Int

  init(limit: Int = 8) {
    self.limit = limit
  }

  func presentation(
    checks: [ReviewCheck],
    visibleNonProblemCheckLimit: Int
  ) -> DashboardReviewCheckListPresentation {
    let key = DashboardReviewCheckListPresentationKey(
      checks: checks,
      visibleNonProblemCheckLimit: visibleNonProblemCheckLimit
    )
    if let presentation = presentations[key] {
      return presentation
    }
    let presentation = DashboardReviewCheckListPresentation(
      checks: checks,
      visibleNonProblemCheckLimit: visibleNonProblemCheckLimit
    )
    presentations[key] = presentation
    keys.append(key)
    evictIfNeeded()
    return presentation
  }

  private func evictIfNeeded() {
    while keys.count > limit, let key = keys.first {
      keys.removeFirst()
      presentations.removeValue(forKey: key)
    }
  }
}
