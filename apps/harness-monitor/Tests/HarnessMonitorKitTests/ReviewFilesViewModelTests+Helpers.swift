import Foundation
import Testing

@testable import HarnessMonitorKit

extension ReviewFilesViewModelTests {
  func makeFile(
    path: String,
    additions: UInt32 = 0,
    deletions: UInt32 = 0,
    viewed: ReviewFileViewedState = .unviewed
  ) -> ReviewFile {
    ReviewFile(
      path: path,
      changeType: .modified,
      additions: additions,
      deletions: deletions,
      viewerViewedState: viewed
    )
  }

  func makeResponse(
    files: [ReviewFile],
    headRefOid: String = "head-a"
  ) -> ReviewsFilesListResponse {
    ReviewsFilesListResponse(
      pullRequestID: "pr-1",
      number: 42,
      headRefOid: headRefOid,
      headRefName: "renovate/foo",
      baseRefOid: "base-a",
      baseRefName: "main",
      repositoryFullName: "owner/repo",
      viewerCanMarkViewed: true,
      files: files,
      fetchedAt: "2026-05-22T12:00:00Z"
    )
  }
}
