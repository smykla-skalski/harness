import Foundation

public typealias DaemonPushEventStream = AsyncThrowingStream<DaemonPushEvent, Error>
public typealias TimelineBatchHandler =
  @Sendable (_ entries: [TimelineEntry], _ batchIndex: Int, _ batchCount: Int) async -> Void
public typealias TimelineWindowBatchHandler =
  @Sendable (_ response: TimelineWindowResponse, _ batchIndex: Int, _ batchCount: Int) async -> Void

public enum TimelineScope: String, Codable, Equatable, Sendable {
  case full
  case summary
}
