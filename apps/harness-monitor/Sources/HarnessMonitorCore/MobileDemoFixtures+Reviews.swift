import Foundation

extension MobileDemoFixtures {
  static func demoReviews(stationID: String, now: Date) -> [MobileReviewSummary] {
    [
      demoReview812(stationID: stationID, now: now),
      demoReview804(stationID: stationID, now: now),
    ]
  }

  static func demoReview812(
    stationID: String,
    now: Date
  ) -> MobileReviewSummary {
    MobileReviewSummary(
      id: "review-812",
      stationID: stationID,
      repository: "smykla-skalski/harness",
      number: 812,
      url: "https://github.com/smykla-skalski/harness/pull/812",
      title: "Add command receipt audit trail",
      author: "bart",
      state: "open",
      checksSummary: "8/8 checks green",
      headSha: "abc123",
      mergeable: "mergeable",
      reviewStatus: "review_required",
      checkStatus: "success",
      policyBlocked: false,
      isDraft: false,
      labels: ["mobile", "ready"],
      checks: [
        MobileReviewCheckSnippet(
          id: "check-mobile-tests",
          name: "HarnessMonitorMobileTests",
          status: "completed",
          conclusion: "success",
          checkSuiteID: "suite-mobile-tests"
        ),
        MobileReviewCheckSnippet(
          id: "check-watch-build",
          name: "HarnessMonitorWatch build",
          status: "completed",
          conclusion: "success",
          checkSuiteID: "suite-watch-build"
        ),
      ],
      files: [
        MobileReviewFileSnippet(
          id: "mobile-store",
          path: "Sources/HarnessMonitorMobile/MobileMonitorStore.swift",
          changeType: "modified",
          additions: 84,
          deletions: 21,
          viewedState: "unviewed",
          isBinary: false
        ),
        MobileReviewFileSnippet(
          id: "relay-executor",
          path: "Sources/HarnessMonitorMacRelay/MobileRelayCommandAPIExecutor.swift",
          changeType: "modified",
          additions: 42,
          deletions: 8,
          viewedState: "viewed",
          isBinary: false
        ),
      ],
      activity: [
        MobileReviewActivitySnippet(
          id: "activity-review-request",
          kind: "reviewRequested",
          actor: "codex",
          summary: "Requested review from bart",
          recordedAt: now.addingTimeInterval(-8 * 60)
        ),
        MobileReviewActivitySnippet(
          id: "activity-commit",
          kind: "commit",
          actor: "codex",
          summary: "Commit abc123: Add receipt audit trail",
          recordedAt: now.addingTimeInterval(-5 * 60)
        ),
      ],
      additions: 126,
      deletions: 29,
      needsYou: true,
      updatedAt: now.addingTimeInterval(-5 * 60)
    )
  }

  static func demoReview804(
    stationID: String,
    now: Date
  ) -> MobileReviewSummary {
    MobileReviewSummary(
      id: "review-804",
      stationID: stationID,
      repository: "smykla-skalski/harness",
      number: 804,
      url: "https://github.com/smykla-skalski/harness/pull/804",
      title: "Tighten replay protection tests",
      author: "codex",
      state: "open",
      checksSummary: "2 checks running",
      headSha: "def456",
      mergeable: "unknown",
      reviewStatus: "none",
      checkStatus: "pending",
      policyBlocked: false,
      isDraft: true,
      labels: ["security", "tests"],
      checks: [
        MobileReviewCheckSnippet(
          id: "check-crypto-tests",
          name: "HarnessMonitorCryptoTests",
          status: "in_progress",
          conclusion: "none",
          checkSuiteID: "suite-crypto-tests"
        )
      ],
      files: [
        MobileReviewFileSnippet(
          id: "crypto-tests",
          path: "Tests/HarnessMonitorCryptoTests/MobilePairingTests.swift",
          changeType: "modified",
          additions: 31,
          deletions: 4,
          viewedState: "unviewed",
          isBinary: false
        )
      ],
      activity: [
        MobileReviewActivitySnippet(
          id: "activity-draft",
          kind: "convertToDraft",
          actor: "codex",
          summary: "Converted to draft",
          recordedAt: now.addingTimeInterval(-19 * 60)
        )
      ],
      additions: 31,
      deletions: 4,
      needsYou: false,
      updatedAt: now.addingTimeInterval(-19 * 60)
    )
  }
}
