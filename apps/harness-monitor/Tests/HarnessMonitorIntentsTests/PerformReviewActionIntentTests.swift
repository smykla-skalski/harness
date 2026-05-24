import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class PerformReviewActionIntentTests: XCTestCase {
  func testRerunChecksRoutesToSourceWithoutConfirmation() async throws {
    let stub = StubReviewsActionSource()
    let intent = PerformReviewActionIntent(
      action: .rerunChecks,
      pullRequest: Self.makeEntity(id: "owner/repo#1"),
      source: stub
    )

    _ = try await intent.perform()

    let recorded = await stub.recordedReruns
    XCTAssertEqual(recorded, ["owner/repo#1"])
  }

  func testAddLabelRoutesTrimmedLabelToSource() async throws {
    let stub = StubReviewsActionSource()
    let intent = PerformReviewActionIntent(
      action: .addLabel,
      pullRequest: Self.makeEntity(id: "owner/repo#2"),
      label: "   needs-review  ",
      source: stub
    )

    _ = try await intent.perform()

    let recorded = await stub.recordedLabels
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded.first?.pullRequestID, "owner/repo#2")
    XCTAssertEqual(recorded.first?.label, "needs-review")
  }

  func testAddLabelWithoutLabelThrows() async {
    let stub = StubReviewsActionSource()
    let intent = PerformReviewActionIntent(
      action: .addLabel,
      pullRequest: Self.makeEntity(id: "owner/repo#3"),
      label: "   ",
      source: stub
    )

    do {
      _ = try await intent.perform()
      XCTFail("expected throw when label is missing")
    } catch let error as IntentDaemonError {
      switch error {
      case .rpcFailed(_, let message):
        XCTAssertTrue(message.contains("label"), "message should explain missing label")
      default:
        XCTFail("expected rpcFailed, got \(error)")
      }
    } catch {
      XCTFail("expected IntentDaemonError, got \(error)")
    }

    let recordedLabels = await stub.recordedLabels
    XCTAssertTrue(recordedLabels.isEmpty)
  }

  func testMergeWithoutMethodThrows() async {
    let stub = StubReviewsActionSource()
    let intent = PerformReviewActionIntent(
      action: .merge,
      pullRequest: Self.makeEntity(id: "owner/repo#4"),
      source: stub
    )

    do {
      _ = try await intent.perform()
      XCTFail("expected throw when merge method is missing")
    } catch let error as IntentDaemonError {
      switch error {
      case .rpcFailed(_, let message):
        XCTAssertTrue(message.contains("merge method"), "message should explain missing method")
      default:
        XCTFail("expected rpcFailed, got \(error)")
      }
    } catch {
      XCTFail("expected IntentDaemonError, got \(error)")
    }

    let recordedMerges = await stub.recordedMerges
    XCTAssertTrue(recordedMerges.isEmpty)
  }

  // MARK: - helpers

  private static func makeEntity(id: String) -> PullRequestEntity {
    PullRequestEntity(
      id: id,
      title: "Title for \(id)",
      repository: id.split(separator: "#").first.map(String.init) ?? "owner/repo",
      number: Int(id.split(separator: "#").last.map(String.init) ?? "0") ?? 0,
      authorLogin: "alice",
      state: .open,
      reviewerSummary: "0/0 approvals",
      lastUpdated: nil,
      url: URL(string: "https://example.com/\(id)")
    )
  }
}
