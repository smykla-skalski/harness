import Foundation
import Observation

/// Observable slice consumed by the toolbar bell. It listens to decision lifecycle events and
/// keeps the open-count summary in sync for the toolbar badge.
@MainActor
@Observable
public final class SupervisorToolbarSlice {
  public private(set) var count: Int = 0
  public private(set) var maxSeverity: DecisionSeverity?
  @ObservationIgnored private var ingestTask: Task<Void, Never>?

  public init() {}

  @discardableResult
  public func ingest(
    events: AsyncStream<DecisionStore.DecisionEvent>,
    loadCounts: @escaping @Sendable () async -> [DecisionSeverity: Int]
  ) -> Task<Void, Never> {
    stop()
    let task = Task { @MainActor [weak self] in
      for await _ in events {
        guard let self else {
          return
        }
        let counts = await loadCounts()
        self.apply(counts: counts)
      }
    }
    ingestTask = task
    return task
  }

  public func start(decisions: DecisionStore) {
    stop()
    ingestTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      self.apply(counts: (try? await decisions.openCountBySeverity()) ?? [:])
      for await _ in decisions.events {
        self.apply(counts: (try? await decisions.openCountBySeverity()) ?? [:])
      }
    }
  }

  public func stop() {
    ingestTask?.cancel()
    ingestTask = nil
    count = 0
    maxSeverity = nil
  }

  public func refresh(counts: [DecisionSeverity: Int]) {
    apply(counts: counts)
  }

  private func apply(counts: [DecisionSeverity: Int]) {
    let nextCount = counts.values.reduce(0, +)
    let nextMaxSeverity = Self.maxSeverity(in: counts)
    if count != nextCount {
      count = nextCount
    }
    if maxSeverity != nextMaxSeverity {
      maxSeverity = nextMaxSeverity
    }
  }

  private static func maxSeverity(in counts: [DecisionSeverity: Int]) -> DecisionSeverity? {
    for severity in DecisionSeverity.allCases.reversed() where (counts[severity] ?? 0) > 0 {
      return severity
    }
    return nil
  }
}
