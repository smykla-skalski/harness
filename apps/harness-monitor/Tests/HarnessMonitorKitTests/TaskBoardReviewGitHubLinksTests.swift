import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board review GitHub links")
struct TaskBoardReviewGitHubLinksTests {
  @Test("Pull request link uses a continuous repository and number identity")
  func pullRequestLink() {
    let url = TaskBoardReviewGitHubLinks.pullRequest(
      repository: "smykla-skalski/harness",
      number: 901
    )

    #expect(url?.absoluteString == "https://github.com/smykla-skalski/harness/pull/901")
  }

  @Test("Revision link targets the immutable commit")
  func revisionLink() {
    let revision = "b08dca3c08f699e66ee97162f425539667936848"
    let url = TaskBoardReviewGitHubLinks.revision(
      repository: "smykla-skalski/harness",
      revision: revision
    )

    #expect(
      url?.absoluteString
        == "https://github.com/smykla-skalski/harness/commit/\(revision)"
    )
  }

  @Test("File link encodes its path and preserves the line")
  func fileLink() {
    let revision = "b08dca3c08f699e66ee97162f425539667936848"
    let url = TaskBoardReviewGitHubLinks.file(
      repository: "smykla-skalski/harness",
      revision: revision,
      path: "src/runtime bridge/#1.swift",
      line: 42
    )

    #expect(
      url?.absoluteString
        == "https://github.com/smykla-skalski/harness/blob/\(revision)/"
        + "src/runtime%20bridge/%231.swift#L42"
    )
  }
}
